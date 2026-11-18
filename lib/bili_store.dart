import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_api.dart';

/// 登录后拿到的哔哩哔哩账号。
///
/// 只存展示需要的信息 + 一个 cookie 串。cookie 是明文存在本地存档里的，
/// 和浏览器保存登录态是同一个性质 —— 这是「用自己账号登录」的必然代价，
/// 所以界面上要明确写出来，并给一个退出登录的入口。
class BiliSession {
  const BiliSession({
    required this.mid,
    required this.name,
    required this.face,
    required this.cookie,
  });

  final int mid;
  final String name;
  final String face;

  /// 完整 Cookie 请求头，包含 SESSDATA / bili_jct 等
  final String cookie;

  /// 会话是否算「登录着」。
  ///
  /// 只看 mid，不看 cookie：走反代时凭证在服务端手里，客户端手上的可能是
  /// 一张空 cookie 的会话 —— 有些账号扫码成功后 `data.url` 是空的，凭证
  /// 只经 Set-Cookie 落到反代，浏览器读不到。能问到 mid 就说明刚才认证成功。
  ///
  /// 「反代关掉 + 本地没 cookie」这种真用不了的情况，由 [BiliModel.setProxy]
  /// 清掉会话，不会留下「看着登录、请求全是匿名」的假状态。
  bool get isValid => mid > 0;

  Map<String, dynamic> toJson() => {
    'mid': mid,
    'name': name,
    'face': face,
    'cookie': cookie,
  };

  factory BiliSession.fromJson(Map<String, dynamic> json) => BiliSession(
    mid: (json['mid'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    face: json['face'] as String? ?? '',
    cookie: json['cookie'] as String? ?? '',
  );
}

/// 哔哩哔哩数据源的本地状态：开关 + 登录态。
///
/// 做成 ChangeNotifier，是因为「设置页里打开开关」要立刻让搜索页
/// 多出一个来源分段，不能等下次进页面才生效。
class BiliModel extends ChangeNotifier {
  static const _enabledKey = 'bili_source_enabled_v1';
  static const _sessionKey = 'bili_session_v1';
  static const _proxyKey = 'bili_proxy_v1';
  static const _sidKey = 'bili_sid_v1';

  bool _enabled = false;
  BiliSession? _session;
  bool _loaded = false;

  /// 用户配置的反代地址。空串表示直连B站。
  ///
  /// 这个值只是"用户的意愿"，实际是否生效要看 [proxyActive]：
  /// 反代连不上时会自动退回直连，免得配错一个字整个数据源就废掉。
  String _proxy = '';
  bool _proxyActive = false;

  /// 数据源开关。关掉时搜索页完全不出现 B站相关的东西，
  /// 也不会发任何 B站请求。
  bool get enabled => _enabled;
  bool get loaded => _loaded;

  String get proxy => _proxy;

  /// 反代是否真的在用（配置存在且服务可达）
  bool get proxyActive => _proxyActive;

  BiliSession? get session => _session;
  bool get loggedIn => _session?.isValid ?? false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    _proxy = prefs.getString(_proxyKey) ?? '';

    // 先把本地登录态读出来：下面恢复反代时要用它把凭证补回服务端
    final raw = prefs.getString(_sessionKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final session = BiliSession.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        _session = session.isValid ? session : null;
      } catch (_) {
        // 存档坏了就当没登录，不值得为它崩一次启动
        _session = null;
      }
    }

    // 反代要在任何B站请求之前生效，所以这里等它一次。
    // 只在「开了数据源且配了反代」时才等 —— 没开 B站源的人完全不受影响，
    // 否则一个填错的地址会让所有人启动都卡一下。
    if (_enabled && _proxy.isNotEmpty) {
      // 复用上次那张票：新建的会话在服务端是空壳，
      // 而客户端的凭证是持久的，两者一错开就会出现「界面说已登录、请求却是匿名」
      _proxyActive = await BiliApi.restoreProxy(
        _proxy,
        prefs.getString(_sidKey),
      );
      if (!_proxyActive) {
        debugPrint('[bili] 反代不可用，已退回直连：$_proxy');
      } else {
        await _persistSid();
        // 服务端会话可能刚重建过（重启 / 换机器），把本地凭证推回去
        final session = _session;
        if (session != null && session.cookie.isNotEmpty) {
          await BiliApi.importSession(cookie: session.cookie, mid: session.mid);
        }
      }
    }

    _loaded = true;
    notifyListeners();
  }

  /// 把 sid 存起来。不存的话每次启动都换一张新票，
  /// 服务端那份登录态就成了一座孤岛 —— 前端还以为自己登录着。
  Future<void> _persistSid() async {
    final prefs = await SharedPreferences.getInstance();
    final sid = BiliApi.sid;
    if (sid == null || sid.isEmpty) {
      await prefs.remove(_sidKey);
    } else {
      await prefs.setString(_sidKey, sid);
    }
  }

  /// 保存反代地址。返回 false 表示地址不可达，配置没写下去。
  ///
  /// 传空串是关闭反代、回到直连。
  Future<bool> setProxy(String value) async {
    final ok = await BiliApi.setProxy(value);
    if (!ok) return false;

    _proxy = BiliApi.proxyBase;
    _proxyActive = _proxy.isNotEmpty;

    final prefs = await SharedPreferences.getInstance();
    if (_proxy.isEmpty) {
      await prefs.remove(_proxyKey);
      await prefs.remove(_sidKey);
      // 关掉反代之后，凭证只剩服务端那一份。本地没有 cookie 的会话在直连
      // 模式下什么都做不了，留着只会变成「显示已登录、收藏却是空的」
      final session = _session;
      if (session != null && session.cookie.isEmpty) {
        _session = null;
        await prefs.remove(_sessionKey);
      }
    } else {
      await prefs.setString(_proxyKey, _proxy);
      await _persistSid();
      // 新反代上这张票对应的是空会话，把本地凭证补过去，免得再扫一次码
      final session = _session;
      if (session != null && session.cookie.isNotEmpty) {
        await BiliApi.importSession(cookie: session.cookie, mid: session.mid);
      }
    }

    notifyListeners();
    return true;
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  Future<void> setSession(BiliSession? session) async {
    _session = session;
    // 登录后顺手把开关打开 —— 用户扫完码一定是想用它
    if (session != null && !_enabled) {
      _enabled = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, true);
    }
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (session == null) {
      await prefs.remove(_sessionKey);
    } else {
      await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    }
    // 登录成功这一刻必须确保 sid 已落盘：凭证在服务端，
    // 而凭证的钥匙是 sid，弄丢了就要重新扫码
    await _persistSid();
  }
}

/// 全局单例。
final biliModel = BiliModel();
