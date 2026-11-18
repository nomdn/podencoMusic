import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'bili_models.dart';
import 'bili_store.dart';
import 'models.dart';

/// B站接口出错。message 直接给用户看。
class BiliException implements Exception {
  const BiliException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 二维码登录的两步：先拿码，再轮询结果。
class BiliQrCode {
  const BiliQrCode({required this.url, required this.key});

  /// 二维码内容（`https://www.bilibili.com/h5/...`），用 qr_flutter 画出来
  final String url;
  final String key;
}

/// 轮询一次的结果。三个状态 + 成功，用一个类装。
class BiliLoginStatus {
  const BiliLoginStatus({
    required this.code,
    required this.message,
    this.session,
  });

  /// B站的状态码：0 成功，86101 未扫码，86090 已扫码待确认，86038 已失效
  final int code;
  final String message;
  final BiliSession? session;

  bool get done => session != null;
  bool get expired => code == 86038;
}

/// 哔哩哔哩的公开接口封装。
///
/// 踩过的坑都写在方法上，改之前先读注释：
///   · 搜索接口不带 Cookie 会被 WAF 拦成一段 HTML，必须先拿访客 cookie
///   · 用户空间接口（/x/space/wbi/...）对未登录请求一律 -412，
///     连 wbi 签名都救不回来，所以 UP 主视频列表走「搜索 + 按 mid 过滤」
///   · 请求头缺 Origin / sec-ch-ua 时，view 接口也会返回 HTML 而不是 JSON
///   · 音频 CDN 和图片 CDN **不校验 Referer**，播放和封面可以直连
/// 一次取流的结果。
///
/// [quality] 是服务端**实际给的**清晰度（可能低于请求值），[accept] 是它
/// 当前还能提供的全部档位。B站有三层限制叠加：未登录上限 720P；`fnval=1`
/// 只给 MP4 单流；>720P 必须走 DASH（音视频分离，由播放层合并成一路）。
/// 所以菜单要按 [accept] 渲染，不能按用户想要的列。
typedef BiliVideoStream = ({
  String url,

  /// DASH 的音轨地址。**null 表示 [url] 是单流 MP4（durl），音频已经在里面**；
  /// 非 null 时 [url] 只有画面，必须同时播这条音轨，并由播放层做同步。
  String? audioUrl,
  int quality,
  List<int> accept,
  List<String> acceptDesc,
});

class BiliApi {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 真实域名。Referer / Origin 必须用这几个，
  /// 不管请求实际发到哪里 —— B站只认自己的域名。
  static const _homeReal = 'https://www.bilibili.com';
  static const _apiReal = 'https://api.bilibili.com';
  static const _passportReal = 'https://passport.bilibili.com';
  static const _appReal = 'https://app.bilibili.com';

  /// 用户自己部署的反代地址，例如 `https://bili.example.com`。
  ///
  /// 非空时所有请求发到 `<反代>/bili/<上游>`，由服务端补 Cookie 和 Referer。
  /// 这是 Web 端能用B站的唯一途径：浏览器既发不出 Cookie 头，
  /// 也不许跨域请求带 Origin 打 api.bilibili.com（会被风控判 412）。
  static String _proxyBase = '';

  /// 反代会话 id，服务端用来认领 Cookie。
  static String? _sid;

  static bool get proxyEnabled => _proxyBase.isNotEmpty;

  /// 归一化之后的当前反代地址（空串表示直连）
  static String get proxyBase => _proxyBase;

  /// 走反代时的请求前缀；没配置就退回真实域名。
  static String get _home => _proxyBase.isEmpty ? _homeReal : '$_proxyBase/bili/www';
  static String get _api => _proxyBase.isEmpty ? _apiReal : '$_proxyBase/bili/api';
  static String get _passport =>
      _proxyBase.isEmpty ? _passportReal : '$_proxyBase/bili/passport';
  static String get _appHost => _proxyBase.isEmpty ? _appReal : '$_proxyBase/bili/app';

  /// App 端接口（空间投稿列表）。appkey / appSecret 是B站安卓客户端的
  /// 公开固定值，用来算请求签名，不是谁的个人凭证。
  static const _appKey = '4409e2ce8ffd12b8';
  static const _appSecret = '59b43e04ad6965f34319062b478f83dd';

  static const _timeout = Duration(seconds: 15);

  static final http.Client _client = http.Client();

  /// 未登录时的访客 cookie（buvid3 / b_nut），进程内缓存。
  /// 没有它，搜索接口返回的是一张 HTML 风控页。
  static String? _guestCookie;

  /// 已解析的音频直链缓存。B站给的地址带签名，约两小时过期，
  /// 缓存 90 分钟既能省掉重复请求，又不会拿到死链。
  static final Map<String, _CachedUrl> _audioCache = {};

  /// cookie 串里这些是属性而不是凭证，粘贴解析时要跳过。
  static const _cookieAttr = {
    'path',
    'domain',
    'expires',
    'max-age',
    'samesite',
    'secure',
    'httponly',
    'priority',
    'version',
    'comment',
  };

  static bool get hasSession => biliModel.loggedIn;

  // ── 底层请求 ─────────────────────────────────────────────

  static String get _cookieHeader {
    final session = biliModel.session;
    if (session != null && session.cookie.isNotEmpty) {
      // 登录 cookie 在登录时已经把访客部分并进去了
      return session.cookie;
    }
    return _guestCookie ?? '';
  }

  static Map<String, String> _headers({String? referer}) => {
    'User-Agent': _ua,
    'Referer': referer ?? '$_homeReal/',
    'Origin': _homeReal,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'sec-ch-ua': '"Chromium";v="126", "Not:A-Brand";v="24"',
    'sec-ch-ua-platform': '"Windows"',
    // 走反代时不带 Cookie：没有必要让本地明文凭证多跑一趟网络，
    // 服务端会按会话 id 补上（而且它手上的那份还更新）
    if (!proxyEnabled && _cookieHeader.isNotEmpty) 'Cookie': _cookieHeader,
    if (proxyEnabled && _sid != null) 'X-Session': _sid!,
  };

  // ── 反代会话 ─────────────────────────────────────────────

  /// 设置反代地址并换一个新会话。
  ///
  /// 传空字符串就是关闭反代，回到直连B站。
  /// 返回是否切换成功 —— 地址不可达时不会把配置写下去，
  /// 免得用户填错一个字就整个数据源用不了。
  static Future<bool> setProxy(String base) async {
    final cleaned = _normalizeProxy(base);
    if (cleaned.isEmpty) {
      _proxyBase = '';
      _sid = null;
      _guestCookie = null;
      _audioCache.clear();
      return true;
    }

    // 地址没变、票也还在，就别白折腾一次
    if (cleaned == _proxyBase && _sid != null) return true;

    final previous = _proxyBase;
    final previousSid = _sid;
    _proxyBase = cleaned;
    // 换地址时旧票一定不属于新服务端，必须重新申请
    _sid = null;
    if (!await ensureSession(force: true)) {
      // 回滚，别让一个打不通的地址把功能弄断
      _proxyBase = previous;
      _sid = previousSid;
      return false;
    }
    _guestCookie = null;
    _audioCache.clear();
    return true;
  }

  /// 启动时恢复反代：优先复用上次那张票。
  ///
  /// 为什么不能无脑新建会话：客户端的登录凭证是持久化的，
  /// 服务端那条会话却只认它自己发的 sid。新建一张票等于把两者拆散 ——
  /// 界面上写着「已登录 UID xxx」，实际每个请求都被当成匿名。
  /// 用户看到的就是「收藏空了」这种毫无线索的现象。
  static Future<bool> restoreProxy(String base, String? savedSid) async {
    final cleaned = _normalizeProxy(base);
    if (cleaned.isEmpty) {
      _proxyBase = '';
      _sid = null;
      return true;
    }

    final previous = _proxyBase;
    final previousSid = _sid;
    _proxyBase = cleaned;

    // 先问服务端还认不认得这张票
    if (savedSid != null && savedSid.isNotEmpty) {
      _sid = savedSid;
      if (await sessionKnown()) {
        _guestCookie = null;
        _audioCache.clear();
        return true;
      }
      _sid = null;
    }

    if (!await ensureSession(force: true)) {
      _proxyBase = previous;
      _sid = previousSid;
      return false;
    }
    _guestCookie = null;
    _audioCache.clear();
    return true;
  }

  /// 当前的会话 id，供上层持久化。null 表示没有会话（直连或还没建立）。
  static String? get sid => _sid;

  /// 带着当前 sid 问一次服务端：这个会话还在吗？
  static Future<bool> sessionKnown() async {
    final id = _sid;
    if (!proxyEnabled || id == null) return false;
    try {
      final res = await _client
          .get(
            Uri.parse('$_proxyBase/bili/session'),
            headers: {'X-Session': id},
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      return json is Map && json['known'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 从反代会话里取 csrf（bili_jct）。
  ///
  /// 走反代时浏览器读不到扫码响应的 Set-Cookie，客户端本地 session.cookie
  /// 是空的 —— 但反代手里握着完整的 bili_jct。发弹幕/评论的表单里必须带
  /// 它，所以问服务端要（只回 csrf，不回 SESSDATA）。
  static Future<String> proxyCsrf() async {
    final id = _sid;
    if (!proxyEnabled || id == null) return '';
    try {
      final res = await _client
          .get(
            Uri.parse('$_proxyBase/bili/session'),
            headers: {'X-Session': id},
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return '';
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map || json['known'] != true) return '';
      return json['csrf']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 把本地保存的 Cookie 推回服务端，让会话恢复登录态。
  ///
  /// 修的是「服务端状态丢了但客户端还有凭证」：反代重启且没落盘、换机器、
  /// 从旧反代切到新反代。这些情况让用户重新扫码是没必要的。
  /// 接口只写不读，不会回显任何凭证内容。
  static Future<bool> importSession({String? cookie, int mid = 0}) async {
    if (!proxyEnabled) return false;
    if (cookie == null || cookie.isEmpty) return false;
    if (!await ensureSession()) return false;

    try {
      final res = await _client
          .post(
            Uri.parse('$_proxyBase/bili/session/import'),
            headers: {
              'X-Session': _sid!,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'cookie': cookie, 'mid': '$mid'}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      return json is Map && json['logged_in'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 去掉末尾斜杠、补上协议。用户往往只填 `bili.example.com`。
  static String _normalizeProxy(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 拿一个会话 id。服务端重启后本地 sid 会失效，
  /// 所以 force 为真时无条件重新申请。
  ///
  /// 超时给得比普通接口短：这一步在启动路径上，反代挂了的话
  /// 让用户对着黑屏等 15 秒是不可接受的，5 秒探不通就退回直连。
  static Future<bool> ensureSession({bool force = false}) async {
    if (!proxyEnabled) return false;
    if (!force && _sid != null) return true;
    try {
      final res = await _client
          .post(Uri.parse('$_proxyBase/bili/session'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      final sid = json is Map ? json['sid']?.toString() : null;
      if (sid == null || sid.isEmpty) return false;
      _sid = sid;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 探测成功的固定前缀。
  ///
  /// 设置页靠 `startsWith` 判断这次测试过没过，所以它不能是随手写的文案 ——
  /// 要改措辞就改这个常量，别只改下面那句字符串。
  static const probeOkPrefix = '通道正常';

  /// 探一下反代是否活着，设置页的「测试」按钮用。
  static Future<String> probeProxy(String base) async {
    final cleaned = _normalizeProxy(base);
    if (cleaned.isEmpty) return '地址是空的';
    try {
      final res = await _client
          .get(Uri.parse('$cleaned/healthz'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return '服务返回 ${res.statusCode}';
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map || json['ok'] != true) return '这个地址不太像B站反代';
      final version = json['version']?.toString() ?? '';
      return '$probeOkPrefix${version.isEmpty ? '' : '（v$version）'}';
    } catch (e) {
      return '连不上：$e';
    }
  }

  /// 把上游地址包一层反代。
  ///
  /// 这一层在 Web 上是必需的：<audio> 直接指向 CDN 时，
  /// 浏览器既补不了 Referer，也拿不到 403 之外的任何解释。
  static String _mediaUrl(String bvid, String raw, String kind) =>
      _mediaUrls(bvid, [raw], kind);

  /// 多个候选合成一条地址：`u=a&u=b&u=c`，服务端按顺序试。
  ///
  /// 为什么要合并而不是返回三条：playurl 给的备用地址是同一份资源的镜像，
  /// 对调用方来说只是"一条音轨"，把重试逻辑留在服务端，
  /// 上层（播放器、下载器）就不用关心节点抽风这回事。
  /// 一组候选媒体地址 -> 播放器能直接用的列表。
  ///
  /// Web + 反代：合成一条反代地址（服务端按序重试所有上游节点）。
  /// 其他情况：原样返回，交给播放器逐个尝试。
  static List<String> _mediaUrlList(String bvid, List<String> raws, String kind) {
    if (raws.isEmpty) return const [];
    if (!kIsWeb || !proxyEnabled) return raws;
    return [_mediaUrls(bvid, raws, kind)];
  }

  static String _mediaUrls(String bvid, List<String> raws, String kind) {
    if (raws.isEmpty) return '';
    // 媒体流只有 Web 需要反代：浏览器里的 <video> / <audio> 设不了 Referer，
    // 而视频 CDN 强制校验它。原生端的 libmpv 和下载器都能自己带请求头，
    // 走直链更快，也不用把用户的上游带宽扛在反代上。
    if (!kIsWeb || !proxyEnabled) return raws.first;
    final query = raws
        .where((url) => url.isNotEmpty)
        .map((url) => 'u=${Uri.encodeComponent(url)}')
        .join('&');
    return '$_proxyBase/bili/media/$bvid?$query&kind=$kind';
  }

  /// 拿一份访客 cookie。失败不抛 —— 有的接口不登录也能用，
  /// 真用不了的时候具体接口自己会报错。
  static Future<void> ensureGuestCookie() async {
    // 走反代时访客身份由服务端维护：浏览器的跨域响应读不到 Set-Cookie，
    // 客户端根本没法自己装配这份 cookie
    if (proxyEnabled) return;
    if (_cookieHeader.isNotEmpty) return;
    try {
      final res = await _client
          .get(
            Uri.parse(_home),
            headers: {'User-Agent': _ua, 'Accept': 'text/html'},
          )
          .timeout(_timeout);
      final jar = _parseSetCookie(res.headers['set-cookie']);
      if (jar.isNotEmpty) {
        _guestCookie = jar.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; ');
      }
    } catch (_) {
      // 拿不到就算了，让具体请求去失败
    }
  }

  static Future<dynamic> _getJson(
    String path, {
    Map<String, String>? query,
    String? referer,
    String? host,
    String? cookieOverride,
  }) {
    // host 不能写成默认参数 `= _api`：那是编译期常量，
    // 而 _api 现在是随反代开关变化的 getter
    final base = host ?? _api;
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    return _requestJson(
      uri.toString(),
      referer: referer,
      cookieOverride: cookieOverride,
    );
  }

  /// 返回原始字节的 GET。弹幕接口是 protobuf，不能用 [_getJson] 去解。
  static Future<List<int>?> _getBytes(
    String path, {
    Map<String, String>? query,
    String? referer,
  }) async {
    final base = _api;
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    if (proxyEnabled) {
      if (!await ensureSession()) return null;
    } else {
      await ensureGuestCookie();
    }
    try {
      final res = await _client
          .get(uri, headers: _headers(referer: referer))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// 表单 POST（application/x-www-form-urlencoded）。发评论、发弹幕都用它。
  static Future<dynamic> _postForm(
    String path, {
    required Map<String, String> form,
    String? referer,
  }) async {
    final base = _api;
    final uri = Uri.parse('$base$path');
    if (proxyEnabled) {
      if (!await ensureSession()) {
        throw const BiliException('还没接上反代服务，检查一下设置里的反代地址');
      }
    } else {
      await ensureGuestCookie();
    }
    final headers = _headers(referer: referer);
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    try {
      final res = await _client
          .post(uri, headers: headers, body: form)
          .timeout(_timeout);
      final body = utf8.decode(res.bodyBytes);
      try {
        return jsonDecode(body);
      } on FormatException {
        throw BiliException('B站返回了非 JSON：${res.statusCode}');
      }
    } on TimeoutException {
      throw const BiliException('B站接口超时，检查一下网络');
    } catch (e) {
      if (e is BiliException) rethrow;
      throw BiliException('连不上B站：$e');
    }
  }

  /// 完整 URL 版本。App 端接口的签名对参数顺序和编码方式敏感，
  /// 不能交给 Uri 去重排，所以单独留一个入口。
  static Future<dynamic> _requestJson(
    String url, {
    String? referer,
    String? cookieOverride,
    bool retried = false,
    Map<String, String>? headerSink,
  }) async {
    if (proxyEnabled) {
      // 服务端重启后旧 sid 会变成匿名会话，表现是「明明登录了却看不到收藏」。
      // 这里统一保证先有个会话，拿不到就直接说清楚，比默默降级好。
      if (!await ensureSession()) {
        throw const BiliException('还没接上反代服务，去设置里看看『接口反代』地址，博士');
      }
    } else {
      await ensureGuestCookie();
    }

    final uri = Uri.parse(url);
    final headers = _headers(referer: referer);
    if (!proxyEnabled && cookieOverride != null) {
      headers['Cookie'] = cookieOverride;
    }

    final http.Response res;
    try {
      res = await _client.get(uri, headers: headers).timeout(_timeout);
    } on TimeoutException {
      throw BiliException(
        proxyEnabled ? '反代一直没回话，确认下服务还在跑' : 'B站接口超时，检查一下网络',
      );
    } catch (e) {
      throw BiliException(proxyEnabled ? '连不上反代：$e' : '连不上B站：$e');
    }

    // 服务端不认识这张票（重启且状态没落盘 / 换了反代）：重建一次再重试。
    //
    // 不处理的话请求会「成功」—— 只是降级成了匿名。用户那边看到的是
    // 「收藏空了、字幕没了」，而设置页还写着「已登录」，很难自己查出来。
    if (proxyEnabled && !retried && res.headers['x-session-known'] == '0') {
      if (await ensureSession(force: true)) {
        // 新会话是空的，把客户端手上那份凭证补回去，省掉一次重新扫码
        final saved = biliModel.session;
        if (saved != null) {
          await importSession(cookie: saved.cookie, mid: saved.mid);
        }
        return _requestJson(
          url,
          referer: referer,
          cookieOverride: cookieOverride,
          retried: true,
          headerSink: headerSink,
        );
      }
    }

    // 需要读响应头的调用方（扫码轮询要拿 Set-Cookie）在这里取一份
    if (headerSink != null) headerSink.addAll(res.headers);

    final body = utf8.decode(res.bodyBytes);

    if (res.statusCode == 401) {
      throw const BiliException('反代拒绝了这次请求，核对一下 X-Token 密钥');
    }
    if (res.statusCode == 429) {
      throw const BiliException('请求密度过高，终端正在冷却。请稍后再试');
    }
    if (res.statusCode == 412) {
      throw const BiliException('侦测到对方的风控拦截。更换检索词，或稍后重试');
    }
    if (res.statusCode != 200) {
      throw BiliException('B站接口返回 ${res.statusCode}');
    }

    final dynamic json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      // 风控页是 HTML，走到这里说明请求特征被判定异常
      throw const BiliException('回传的不是作战数据，而是一份网页。疑似风控拦截，请稍后再试');
    }

    if (json is! Map<String, dynamic>) {
      throw const BiliException('回传的数据格式无法解码');
    }

    final code = (json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw BiliException(_messageFor(code, json['message']?.toString()));
    }
    return json['data'];
  }

  static String _messageFor(int code, String? raw) {
    switch (code) {
      case -352:
      case -412:
        return '被B站风控拦了，稍后再试（或登录后再试）';
      case -404:
        return '内容不存在或已被删除';
      case -403:
        return '没有访问权限';
      case 62002:
        return '该视频不可见';
      case 62004:
        return '稿件审核中';
      default:
        return raw == null || raw.isEmpty ? '接口回报异常（$code）' : raw;
    }
  }

  // ── 搜索 ─────────────────────────────────────────────────

  /// 搜视频。每页 20 条，B站自己也就给这么多。
  static Future<List<BiliVideo>> searchVideos(
    String keyword, {
    int page = 1,
  }) async {
    final data = await _getJson(
      '/x/web-interface/search/type',
      query: {
        'search_type': 'video',
        'keyword': keyword,
        'page': '$page',
      },
      referer: 'https://search.bilibili.com/',
    );

    final result = data is Map ? data['result'] : null;
    if (result is! List) return const [];

    return result
        .whereType<Map<String, dynamic>>()
        .map(BiliVideo.fromJson)
        .where((video) => video.bvid.isNotEmpty)
        .toList();
  }

  /// 搜 UP 主。
  static Future<List<BiliUp>> searchUps(String keyword, {int page = 1}) async {
    final data = await _getJson(
      '/x/web-interface/search/type',
      query: {
        'search_type': 'bili_user',
        'keyword': keyword,
        'page': '$page',
      },
      referer: 'https://search.bilibili.com/',
    );

    final result = data is Map ? data['result'] : null;
    if (result is! List) return const [];

    return result
        .whereType<Map<String, dynamic>>()
        .map(BiliUp.fromJson)
        .where((up) => up.mid > 0)
        .toList();
  }

  /// 某个 UP 主的视频。
  ///
  /// 两条路，按可用性依次尝试：
  ///   1. App 端空间接口 `/x/v2/space/archive/cursor` —— **不需要登录、
  ///      不需要 wbi 签名**，一次给 20 条最新投稿，最准。代价是要按
  ///      appkey + secret 算一个 md5 签名（客户端 appkey 是公开的）。
  ///   2. 网页搜索接口「UP名 [+ 关键词]」+ 按 mid 过滤 —— 网页空间接口
  ///      对未登录请求一律 -412，连 wbi 都救不回来，只能这么凑。
  ///
  /// [keyword] 非空时就是「在这个 UP 的视频里搜」，那条路只能走 2。
  static Future<List<BiliVideo>> upVideos(
    int mid,
    String upName, {
    String keyword = '',
    int maxPages = 3,
  }) async {
    final clean = keyword.trim();

    if (clean.isEmpty) {
      try {
        final list = await _spaceVideos(mid);
        if (list.isNotEmpty) return list;
      } catch (_) {
        // 接口换了或被限流就当没这回事，退到搜索去凑
      }
    }

    final query = clean.isEmpty ? upName : '$upName $clean';

    final videos = <BiliVideo>[];
    final seen = <String>{};

    for (var page = 1; page <= maxPages; page++) {
      final batch = await searchVideos(query, page: page);
      for (final video in batch) {
        if (video.mid == mid && seen.add(video.bvid)) videos.add(video);
      }
      // 不满一页说明到底了，没必要继续翻
      if (batch.length < 20) break;
    }

    return videos;
  }

  /// App 端「UP 主全部投稿」。
  ///
  /// 签名 = md5(按 key 排序的 query + appSecret)。参数顺序和编码必须
  /// 和实际发出去的一致，所以这里自己拼 URL，不走 _getJson 的 query 参数。
  static Future<List<BiliVideo>> _spaceVideos(int mid) async {
    final params = <String, String>{
      'appkey': _appKey,
      'mobi_app': 'android',
      'platform': 'android',
      'ps': '20',
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'vmid': '$mid',
    };

    final sorted = params.keys.toList()..sort();
    final query = sorted
        .map((key) => '$key=${Uri.encodeQueryComponent(params[key]!)}')
        .join('&');
    final sign = md5.convert(utf8.encode('$query$_appSecret')).toString();

    final data = await _requestJson(
      '$_appHost/x/v2/space/archive/cursor?$query&sign=$sign',
      referer: 'https://space.bilibili.com/$mid/video',
    );

    final items = data is Map ? data['item'] : null;
    if (items is! List) return const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => BiliVideo.fromSpaceJson(json, mid: mid))
        .where((video) => video.bvid.isNotEmpty)
        .toList();
  }

  // ── 播放 ─────────────────────────────────────────────────

  /// 换出可以直接播的音频直链。
  ///
  /// 两步：先 view 拿分P cid，再 playurl 拿 dash 音轨。选码率最高的一条
  /// （30280 通常是 192k，30216 只有 64k）。
  /// 这条音轨的**全部**可用地址，按「好用的排前面」排好序。
  ///
  /// playurl 会同时给好几个地址：主站 CDN（`upos-sz-*`、`upos-hz-*`）和
  /// PCDN 边缘节点（`*.mcdn.bilivideo.cn:8082`、`edge.mountaintoys.cn`）。
  /// 这些节点各自会抽风 —— 实测同一个地址前一次 206、过一会儿直接连不上；
  /// 也没法「指定」节点：`upsig`/`mcdnid` 是跟节点绑的，改 host 一律 403。
  /// 所以只能把候全都收着，让上层按顺序试、谁通用谁，并记住结果。
  ///
  /// 主站 CDN 排前面：实测更快，也不会像 PCDN 那样回
  /// `Content-Type: application/octet-stream`。
  static Future<List<String>> audioUrls(String bvid) async {
    final cached = _audioCache[bvid];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      // 缓存的是原始地址，返回前仍要过一遍反代包装
      return _mediaUrlList(bvid, cached.urls, 'audio');
    }

    final referer = '$_homeReal/video/$bvid/';
    final view = await _getJson(
      '/x/web-interface/view',
      query: {'bvid': bvid},
      referer: referer,
    );

    final cid = view is Map ? view['cid']?.toString() ?? '' : '';
    if (cid.isEmpty) throw const BiliException('无法读取该影像的分段编号（CID）');

    final play = await _getJson(
      '/x/player/playurl',
      query: {
        'bvid': bvid,
        'cid': cid,
        // 16 = 只要 DASH。音轨是 fragmented MP4，libmpv 能直接流式解，
        // 不需要像以前那样为了 Android MediaPlayer 退回 360P 合并流。
        'fnval': '16',
        'fnver': '0',
        'fourk': '0',
      },
      referer: referer,
    );

    final urls = _pickAudioUrls(play);
    if (urls.isEmpty) throw const BiliException('未检索到可用音轨，这个影像没有声音');

    // 缓存里存的是上游原始地址：反代地址是可配置的，改配置后不能拿到旧前缀
    _audioCache[bvid] = _CachedUrl(
      urls,
      DateTime.now().add(const Duration(minutes: 90)),
    );
    // Web 上走反代时把所有候选合成一条地址，由服务端逐个试；
    // 原生端原样返回，让播放器自己按顺序换节点（见 PlayerModel._retrySource）
    return _mediaUrlList(bvid, urls, 'audio');
  }

  /// 第一个候选，够用的场景（下载）直接用这个
  static Future<String> audioUrl(String bvid) async =>
      (await audioUrls(bvid)).first;

  static List<String> _pickAudioUrls(dynamic play) {
    final urls = <String>[];
    void add(dynamic value) {
      if (value is String && value.isNotEmpty && !urls.contains(value)) {
        urls.add(value);
      }
    }

    if (play is Map) {
      final dash = play['dash'];
      if (dash is Map) {
        final audio = dash['audio'];
        if (audio is List && audio.isNotEmpty) {
          final tracks = audio.whereType<Map>().toList()
            ..sort(
              (a, b) => ((b['bandwidth'] as num?)?.toInt() ?? 0).compareTo(
                (a['bandwidth'] as num?)?.toInt() ?? 0,
              ),
            );
          final best = tracks.first;
          add(best['baseUrl'] ?? best['base_url']);
          final backups = best['backupUrl'] ?? best['backup_url'];
          if (backups is List) backups.forEach(add);
        }
      }

      // 很老的视频没有 dash，只有一整个 m4a/flv
      if (urls.isEmpty) {
        final durl = play['durl'];
        if (durl is List && durl.isNotEmpty) {
          final first = durl.first;
          if (first is Map) add(first['url']);
        }
      }
    }

    // 主站 CDN 提到前面，其余保持原顺序（手写分组，List.sort 不稳定）
    final mainCdn = <String>[];
    final others = <String>[];
    for (final url in urls) {
      (url.contains('upos-') ? mainCdn : others).add(url);
    }
    return [...mainCdn, ...others];
  }

  /// 带画面的播放地址。
  ///
  /// 和 [audioUrl] 走同一个 playurl，但有两处必须不一样，否则播不了：
  ///
  /// 1. `fnval=1` —— 返回音视频合一的 mp4（durl），声音画面天然同步；
  /// 2. `platform=html5` —— 不加这个，B站经常把地址分到 PCDN 边缘节点
  ///    （`*.mcdn.bilivideo.cn`、`edge.mountaintoys.cn`），那些节点在部分
  ///    网络下直接连不上。加了才会给主站 CDN（`upos-sz-*.bilivideo.com`）。
  ///
  /// 拿到地址还不算完，请求它时**必须**带 [streamHeaders] 里的两个头，
  /// 否则 CDN 一律 403（实测：裸请求 403，带 UA + 视频页 Referer 才有 206）。
  /// 视频画面的原始宽高比。
  ///
  /// 用 view 接口的 `dimension` 字段，而不是播放器上报的 size ——
  /// 播放器刚初始化时 size 常常还是空的，而 `aspectRatio` 在 size 为空时
  /// 会兜底成 1.0，直接用它算会把画面摆成正方形（看起来就是横向拉伸）。
  /// 接口给的是真值，不依赖播放器。
  ///
  /// 失败返回 null，调用方自己兜底。
  static Future<double?> videoAspectRatio(String bvid) async {
    try {
      final view = await _getJson(
        '/x/web-interface/view',
        query: {'bvid': bvid},
        referer: '$_homeReal/video/$bvid/',
      );
      if (view is! Map) return null;
      final dim = view['dimension'];
      if (dim is! Map) return null;
      final w = (dim['width'] as num?)?.toDouble() ?? 0;
      final h = (dim['height'] as num?)?.toDouble() ?? 0;
      final rotate = (dim['rotate'] as num?)?.toInt() ?? 0;
      if (w <= 0 || h <= 0) return null;
      // rotate 90/270 = 竖屏拍摄，显示时宽高互换
      return (rotate == 90 || rotate == 270) ? h / w : w / h;
    } catch (_) {
      return null;
    }
  }

  /// B站高级弹幕（mode 7）的绝对像素坐标系。
  ///
  /// **不是 1280×720** —— 那个数字是「超小杯」那条 x=1100 误导出来的假设。
  /// 权威定义见 danmaku2ass：绝对像素坐标按弹幕发送日期选历史播放器基准，
  /// 2013-11-10 **之后是 862×568**（之前是 545×388）。
  ///
  /// 用真实数据反证过（BV1cD4y1S7Yx，172 条 mode 7）：整段弹幕的 x 落在
  /// 0~797、y 落在 0~554，并且存在 `["0","554"]` / `["0","1"]` 这类贴着
  /// 画面底边的横线 —— 画布必须 ≥ 797×554 且高约 568 才装得下。682×438
  /// （DanmakuFlameMaster 的 Android 引擎基准）明显不够，那是 App 端自己
  /// 的参考系，不是 Web 播放器发弹幕时用的。
  ///
  /// 按 1280 除会让 x 偏小 → 整体左偏、字也偏小；按 720 除会让 y 偏小 →
  /// 整体上移。实测这个视频里 `▲▲▲` 原本算出 x=0.063，正确值是 0.094，
  /// 差 33px；y 差 70px。
  static const double _advCanvasW = 862;
  static const double _advCanvasH = 568;

  /// 常用清晰度。B站的 qn 值：16=360P、32=480P、64=720P、80=1080P、
  /// 112=1080P+、120=4K。未登录或没有对应权限时服务端会自动降级，
  /// 所以传高值不会报错，只是拿不到。
  static const Map<int, String> qualityLabels = {
    16: '360P',
    32: '480P',
    64: '720P',
    80: '1080P',
    112: '1080P+',
    120: '4K',
  };

  static Future<BiliVideoStream> videoStream(
    String bvid, {
    int qn = 64,
    /// 强制走合并流（MP4）。DASH 音轨起不来时由播放层置位重试 ——
    /// 否则会静音播完整个视频：DASH 的画面流里本来就没有声音。
    bool forceMuxed = false,
  }) async {
    final referer = '$_homeReal/video/$bvid/';
    final view = await _getJson(
      '/x/web-interface/view',
      query: {'bvid': bvid},
      referer: referer,
    );

    final cid = view is Map ? view['cid']?.toString() ?? '' : '';
    if (cid.isEmpty) throw const BiliException('无法读取该影像的分段编号（CID）');

    // DASH 只在登录态下有意义。
    //
    // 未登录时实测（BV1GJ411x7h7 / BV1uv411q7Mv）：`accept_quality` 照样
    // 声明 [112,80,64,32,16]，但 `dash.video` 里只有 32 和 16 —— 也就是
    // 480P 封顶，比 MP4 单流能拿到的 720P 还差。所以未登录继续走 durl。
    //
    // 另外 `platform=html5` 会把服务端钉死在 durl 模式（带它就永远没有
    // dash 字段），两条路不能共用一套参数。
    //
    // DASH 现在四端都能用了：
    //   · 原生端（Windows / Linux / Android）交给 libmpv，画面流 + 外挂
    //     音轨都在同一个播放器里，只有一个音频输出，不存在抢 AudioFocus；
    //   · Web 端由 WebVideoPlayback 起两个 <video> 自己对时间轴。
    // 只有播放层明确要求合并流（[forceMuxed]，DASH 音轨挂了之后的重试）
    // 时才退回 durl。
    final wantDash = hasSession && !forceMuxed;
    final play = await _getJson(
      '/x/player/playurl',
      query: {
        'bvid': bvid,
        'cid': cid,
        // 清晰度由调用方指定；未登录会被服务端降级，接口自己处理
        'qn': qn.toString(),
        'fourk': '1',
        if (wantDash) ...{
          // 4048 = 要 DASH + 4K + HDR + 杜比视界等能力的位掩码
          'fnval': '4048',
          'fnver': '0',
        } else ...{
          'fnval': '1',
          'fnver': '0',
          'platform': 'html5',
          'high_quality': '1',
        },
      },
      referer: referer,
    );

    final dashStream = _parseDashStream(bvid, play, qn);
    if (dashStream != null) return dashStream;

    final durl = play is Map ? play['durl'] : null;
    if (durl is List && durl.isNotEmpty) {
      final first = durl.first;
      if (first is Map) {
        final url = first['url'];
        // 走反代时这层包装同时解决了 Web 端的两个死结：
        // 请求头补不齐（CDN 403）和 video_player_web 忽略 httpHeaders
        if (url is String && url.isNotEmpty) {
          // 服务端可能没给到请求的清晰度（未登录上限 720P、没有 DASH 时
          // 更高档位一律降级），把「实际给的」和「还能选的」一起带回去，
          // 菜单按真实可用项渲染，不要列拿不到的档。
          final actual = (play['quality'] as num?)?.toInt() ?? qn;
          final accept = (play['accept_quality'] as List?)
                  ?.map((e) => (e as num).toInt())
                  .toList() ??
              [actual];
          final desc = (play['accept_description'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const <String>[];
          return (
            url: _mediaUrl(bvid, url, 'video'),
            audioUrl: null,
            quality: actual,
            accept: accept,
            acceptDesc: desc,
          );
        }
      }
    }
    throw const BiliException('未检索到可用画面流');
  }

  /// 从 playurl 的 `dash` 字段里挑出「画面 + 音轨」两条流。
  ///
  /// 返回 null 表示这份响应没有 dash（未登录 / 服务端钉死 durl / 老接口），
  /// 调用方回退到单流 MP4。
  ///
  /// 挑流规则：
  /// - 档位取 `id <= qn` 里最大的（`id` 就是 qn：16/32/64/80/112/116/120）
  /// - 同一档位 B站 会给 hev1 / avc1 / av01 三种编码，**优先 avc1(H.264)**
  ///   —— HEVC 在 Windows 上要系统装了解码器、AV1 在旧浏览器上不支持，
  ///   H.264 是唯一四端都稳的
  /// - 音轨取带宽最大的一条
  /// - `accept` 用 dash 里**真实存在**的档位生成，不要用 `accept_quality`：
  ///   后者是登录后「可选」的声明，未登录时它仍然写着 1080P/1080P+，
  ///   照它渲染菜单就会列出根本拿不到的档
  static BiliVideoStream? _parseDashStream(String bvid, dynamic play, int qn) {
    if (play is! Map) return null;
    final dash = play['dash'];
    if (dash is! Map) return null;

    final videos = (dash['video'] as List?)?.whereType<Map>().toList() ?? const [];
    final audios = (dash['audio'] as List?)?.whereType<Map>().toList() ?? const [];
    if (videos.isEmpty || audios.isEmpty) return null;

    final ids = videos
        .map((e) => (e['id'] as num?)?.toInt() ?? 0)
        .where((id) => id > 0)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    if (ids.isEmpty) return null;

    // 请求的档位可能高过实际给的上限，退到当前最高可用档
    final picked = ids.firstWhere((id) => id <= qn, orElse: () => ids.last);

    final sameQuality =
        videos.where((e) => ((e['id'] as num?)?.toInt() ?? 0) == picked).toList();
    final video = sameQuality.firstWhere(
      (e) => '${e['codecs'] ?? ''}'.startsWith('avc1'),
      orElse: () => sameQuality.first,
    );

    final audio = audios.reduce((a, b) {
      final ba = (a['bandwidth'] as num?)?.toInt() ?? 0;
      final bb = (b['bandwidth'] as num?)?.toInt() ?? 0;
      return bb > ba ? b : a;
    });

    final videoUrl = _dashUrlOf(bvid, video, 'video');
    final audioUrl = _dashUrlOf(bvid, audio, 'audio');
    if (videoUrl.isEmpty || audioUrl.isEmpty) return null;

    // 服务端声明档位 -> 文案，用来给实际档位配描述
    final declared = (play['accept_quality'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    final declaredDesc = (play['accept_description'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final descOf = <int, String>{
      for (var i = 0; i < declared.length; i++)
        declared[i]: i < declaredDesc.length ? declaredDesc[i] : '',
    };

    return (
      url: videoUrl,
      audioUrl: audioUrl,
      quality: picked,
      accept: ids,
      acceptDesc: ids
          .map((id) =>
              descOf[id] ??
              qualityLabels[id] ??
              '${id}P')
          .toList(),
    );
  }

  /// dash 条目 -> 反代地址。B站 同一份资源会给 baseUrl + backupUrl 若干镜像，
  /// 合并成一条交给服务端按序重试（和 durl 那条路一致）。
  static String _dashUrlOf(String bvid, Map item, String kind) {
    final base = (item['baseUrl'] ?? item['base_url'])?.toString() ?? '';
    final backups = ((item['backupUrl'] ?? item['backup_url']) as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final urls = [base, ...backups].where((u) => u.isNotEmpty).toList();
    if (urls.isEmpty) return '';
    return _mediaUrls(bvid, urls, kind);
  }

  /// 拉视频流时必须带的请求头。
  ///
  /// 两个都省不得：
  ///   · 没有 User-Agent —— CDN 403
  ///   · Referer 必须是**这个视频的页面地址**，根域名 `bilibili.com/` 也不行
  ///
  /// Media Foundation / ExoPlayer 默认都不会带 Referer，所以要显式传。
  static Map<String, String> streamHeaders(String bvid) => {
    'User-Agent': _ua,
    'Referer': '$_homeReal/video/$bvid/',
  };

  // ── 视频下载（dash 音视频分离） ────────────────────────────

  /// 拿一个视频「可以下载到本地」的资源集合：视频轨 + 音轨，各带多个候选。
  ///
  /// 为什么不用 [videoStream] 那个 fnval=1 的合并流：那个通道被B站硬性
  /// 封顶在 720P（实测 accept_quality 有 1080P/4K，但 qn 传多少都只回
  /// 720P）。要 1080P/4K/杜比，必须走 fnval=16 的 dash —— 视频轨和音轨
  /// 分开，本地下完再用 ffmpeg 合一个 mp4。
  ///
  /// [preferQn] 是想拿的画质 id（112=1080P, 120=4K, 126=杜比视界），
  /// 账号没会员时会自动降档 —— 接口在 accept_quality 里给了能拿到的上限。
  static Future<BiliDashStreams> dashStreams(String bvid, {int preferQn = 120}) async {
    final referer = '$_homeReal/video/$bvid/';
    final view = await _getJson(
      '/x/web-interface/view',
      query: {'bvid': bvid},
      referer: referer,
    );
    final cid = view is Map ? view['cid']?.toString() ?? '' : '';
    if (cid.isEmpty) throw const BiliException('无法读取该影像的分段编号（CID）');

    final play = await _getJson(
      '/x/player/playurl',
      query: {
        'bvid': bvid,
        'cid': cid,
        'fnval': '16',
        'fnver': '0',
        'fourk': '1',
        'qn': '$preferQn',
        'platform': 'html5',
        'high_quality': '1',
      },
      referer: referer,
    );

    final data = play is Map ? play : null;
    final dash = data?['dash'];
    if (dash is! Map) throw const BiliException('该影像没有可下载的高清流');

    final video = _pickVideoStreams(dash['video'], preferQn);
    final audio = _pickAudioUrls(play);
    if (video.isEmpty || audio.isEmpty) {
      throw const BiliException('未检索到可用的视频轨或音轨');
    }

    return BiliDashStreams(
      bvid: bvid,
      cid: cid,
      quality: (data?['quality'] as num?)?.toInt() ?? 0,
      videoUrls: video,
      audioUrls: audio,
    );
  }

  /// 从 dash 的视频轨里挑指定画质（优先 avc 编码，兼容性最好）。
  static List<String> _pickVideoStreams(dynamic raw, int preferQn) {
    if (raw is! List) return const [];
    final items = raw.whereType<Map>();
    // 先按目标画质过滤，退而求其次再拿最高可用
    var wanted = items.where((v) => (v['id'] as num?)?.toInt() == preferQn).toList();
    if (wanted.isEmpty) {
      final sorted = [...items]
        ..sort((a, b) => ((b['id'] as num?)?.toInt() ?? 0)
            .compareTo((a['id'] as num?)?.toInt() ?? 0));
      wanted = sorted;
    }
    // avc（H.264）排前：ffmpeg 合并后各播放器都能硬解；hevc/av01 兼容性差
    final urls = <String>[];
    void add(Map v) {
      final u = v['baseUrl'] ?? v['base_url'];
      if (u is String && u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }
    for (final v in wanted) {
      if ((v['codecs']?.toString() ?? '').startsWith('avc')) add(v);
    }
    for (final v in wanted) {
      if (!(v['codecs']?.toString() ?? '').startsWith('avc')) add(v);
    }
    return urls;
  }

  // ── 弹幕 ────────────────────────────────────────────────

  /// 拉一个视频的全部弹幕。
  ///
  /// 走 `x/v2/dm/web/seg.so`（protobuf 分段接口）：每段 6 分钟，
  /// 返回 DmSegMobileReply（repeated DanmakuElem）。比老的
  /// `x/v1/dm/list.so`（gzip 压缩的 XML，反代透传时会被压缩搞乱）可靠得多。
  ///
  /// 弹幕量可能上万条，全下回来按时间排好，播放页随进度过滤显示即可。
  static Future<List<BiliDanmaku>> fetchDanmaku(String bvid) async {
    final referer = '$_homeReal/video/$bvid/';
    final cid = await _videoCid(bvid, referer);
    if (cid.isEmpty) return const [];

    final result = <BiliDanmaku>[];
    // 每段 6 分钟，先探到没数据为止；视频一般不超过几小时，兜底 120 段
    for (var seg = 1; seg <= 120; seg++) {
      final bytes = await _getBytes(
        '/x/v2/dm/web/seg.so',
        query: {'type': '1', 'oid': cid, 'segment_index': '$seg'},
        referer: referer,
      );
      if (bytes == null || bytes.isEmpty) break;
      final elems = parseDanmakuProtobuf(bytes);
      if (elems.isEmpty) break;
      result.addAll(elems);
    }
    result.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    // 去重只针对「同一条弹幕被重复抓到」：分段边界重叠或网络重试会带来
    // 真正的重复（同 dmid）。用 ID 去重最准；个别无 ID 的再退回
    // (timeMs|mode|text) 兜底。绝不能只按 (timeMs|text) 去重 ——
    // 同秒刷「666」是合法的不同弹幕（不同 dmid），会被误伤。
    final seenIds = <int>{};
    final seenFallback = <String>{};
    final unique = <BiliDanmaku>[];
    for (final d in result) {
      if (d.id != 0) {
        if (!seenIds.add(d.id)) continue;
      } else {
        final key = '${d.timeMs}|${d.mode}|${d.text}';
        if (!seenFallback.add(key)) continue;
      }
      unique.add(d);
    }
    return unique;
  }

  /// 弹幕 protobuf 解析。见 [BiliDanmaku] 的字段说明。
  static List<BiliDanmaku> parseDanmakuProtobuf(List<int> data) {
    final out = <BiliDanmaku>[];
    var i = 0;
    while (i < data.length) {
      final key = _readVarint(data, i);
      if (key == null) break;
      i = key.$2;
      final tag = key.$1 >> 3;
      final wt = key.$1 & 7;
      if (tag != 1 || wt != 2) {
        // 顶层只有 repeated elems = 1 (length-delimited)，遇到别的就停
        break;
      }
      final len = _readVarint(data, i);
      if (len == null) break;
      i = len.$2;
      final end = i + len.$1;
      final elem = _parseDanmakuElem(data, i, end);
      if (elem != null) out.add(elem);
      i = end;
    }
    return out;
  }

  static BiliDanmaku? _parseDanmakuElem(List<int> data, int start, int end) {
    var timeMs = 0;
    var mode = 1;
    var fontSize = 25;
    var color = 0xFFFFFFFF;
    var id = 0;
    var text = '';
    var i = start;
    while (i < end) {
      final key = _readVarint(data, i);
      if (key == null) break;
      i = key.$2;
      final tag = key.$1 >> 3;
      final wt = key.$1 & 7;
      switch (wt) {
        case 0:
          final v = _readVarint(data, i);
          if (v == null) return null;
          i = v.$2;
          final val = v.$1;
          if (tag == 2) timeMs = val;
          if (tag == 3) mode = val;
          if (tag == 4) fontSize = val;
          if (tag == 5) color = 0xFF000000 | val;
          if (tag == 6) id = val;
          break;
        case 1:
          i += 8;
          break;
        case 2:
          final len = _readVarint(data, i);
          if (len == null) return null;
          i = len.$2;
          final bytes = data.sublist(i, i + len.$1);
          if (tag == 7) {
            text = utf8.decode(bytes);
          }
          i += len.$1;
          break;
        case 5:
          i += 4;
          break;
        default:
          return null;
      }
    }
    if (text.isEmpty) return null;
    // 高级弹幕(mode=7)的 content 是坐标 JSON，不是纯文本 —— 解析出
    // 真正的正文和屏幕坐标，否则界面上会显示一整串方括号数组。
    BiliAdvancedDanmaku? advanced;
    var shown = text;
    if (mode == 7) {
      final parsed = _parseAdvancedDanmaku(text);
      if (parsed == null) {
        // content 不是可解析的坐标数组，原样显示就是一串 JSON 乱码 —— 丢弃
        return null;
      }
      advanced = parsed.$1;
      shown = parsed.$2;
    }
    return BiliDanmaku(
      timeMs: timeMs,
      mode: mode,
      fontSize: fontSize,
      color: color,
      text: shown,
      id: id,
      advanced: advanced,
    );
  }

  /// 解析高级弹幕的坐标数组，返回 (坐标, 正文)。
  /// 解析失败时返回 null，让调用方把原始 content 当普通文本显示。
  static (BiliAdvancedDanmaku, String)? _parseAdvancedDanmaku(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! List || decoded.length < 5) return null;
      String? strAt(int i) => i < decoded.length
          ? decoded[i]?.toString()
          : null;
      // B站坐标有两种单位：≤1 是画布百分比，>1 是 862×568 虚拟画布像素
      // （见 _advCanvasW 注释）。
      double normX(String? raw) {
        final v = double.tryParse(raw ?? '') ?? 0;
        return (v > 1 ? v / _advCanvasW : v).clamp(0.0, 1.0);
      }

      double normY(String? raw) {
        final v = double.tryParse(raw ?? '') ?? 0;
        return (v > 1 ? v / _advCanvasH : v).clamp(0.0, 1.0);
      }

      final x = normX(strAt(0));
      final y = normY(strAt(1));
      // 终点坐标在 [7][8]；运动时长在 [9]（毫秒，0=静止）；
      // 显示时长在 [3]（秒，double 如 "4.07"）—— 没有它弹幕 4 秒就被掐掉
      final toX = normX(strAt(7));
      final toY = normY(strAt(8));
      final moveMs = int.tryParse(strAt(9) ?? '') ?? 0;
      final showMs =
          ((double.tryParse(strAt(3) ?? '') ?? 4) * 1000).round().clamp(
                1000,
                60000,
              );

      // content[2] "a-b"：透明度渐变（"1-0.77" 渐隐到 77%，
      // "0.99-0.2" 是闪烁字符的快速淡出）。整个生存期线性过渡。
      var alpha1 = 1.0;
      var alpha2 = 1.0;
      final alphaParts = (strAt(2) ?? '').split('-');
      if (alphaParts.length == 2) {
        alpha1 = double.tryParse(alphaParts[0]) ?? 1;
        alpha2 = double.tryParse(alphaParts[1]) ?? alpha1;
      }

      // 旋转（度）：[5]=绕 Z 轴（屏幕平面内），[6]=绕 Y 轴（像门一样
      // 绕竖直轴立起来）。CCL 与 danmaku2ass 两个独立逆向一致；
      // 「超小杯」的 [6]=90 就是官方 3D 效果 —— 立起 90° 后经透视
      // 投影呈现为从屏幕中心指向锚点的斜条 + 近大远小。
      final rotZ = double.tryParse(strAt(5) ?? '') ?? 0;
      final rotY = double.tryParse(strAt(6) ?? '') ?? 0;

      final body = strAt(4) ?? '';
      if (body.isEmpty) return null;

      // 路径弹幕（B站的轨迹特效弹幕）：content[14] 是一条 SVG 折线
      // "M647,523L648,522L..."，文字沿它飞行。画布同样是 862×568。
      List<double>? pathXY;
      var pathLen = 0.0;
      if (decoded.length >= 15) {
        final pathRaw = decoded[14]?.toString() ?? '';
        if (pathRaw.startsWith('M')) {
          final parsed = _parseSvgPolyline(pathRaw);
          if (parsed != null) {
            pathXY = parsed.$1;
            pathLen = parsed.$2;
          }
        }
      }

      return (
        BiliAdvancedDanmaku(
          x: x,
          y: y,
          toX: toX,
          toY: toY,
          moveMs: moveMs,
          showMs: showMs,
          fontName: strAt(12) ?? '',
          alpha1: alpha1,
          alpha2: alpha2,
          rotZ: rotZ,
          rotY: rotY,
          pathXY: pathXY,
          pathLength: pathLen,
        ),
        body,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析路径弹幕的 SVG 折线（M/L 指令），归一化到 0~1 并计算总长。
  /// B站生成的全是 M/L 线段，没有曲线指令，正则就够。
  static (List<double>, double)? _parseSvgPolyline(String s) {
    final re = RegExp(r'([ML])\s*(-?\d+(?:\.\d+)?)[,\s]+(-?\d+(?:\.\d+)?)');
    final pts = <double>[];
    var len = 0.0;
    double? px;
    double? py;
    for (final m in re.allMatches(s)) {
      final vx = double.parse(m.group(2)!);
      final vy = double.parse(m.group(3)!);
      // x/y 分维度归一化（画布 862×568），段长也在归一化坐标系里累加，
      // 比例一致，等速取点不受影响
      final nx = (vx > 1 ? vx / _advCanvasW : vx).clamp(0.0, 1.0);
      final ny = (vy > 1 ? vy / _advCanvasH : vy).clamp(0.0, 1.0);
      pts.addAll([nx, ny]);
      if (px != null && py != null) {
        final dx = nx - px;
        final dy = ny - py;
        len += math.sqrt(dx * dx + dy * dy);
      }
      px = nx;
      py = ny;
    }
    if (pts.length < 4) return null;
    return (pts, len);
  }

  static (int, int)? _readVarint(List<int> data, int start) {
    var value = 0;
    var shift = 0;
    var i = start;
    while (i < data.length) {
      final b = data[i++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return (value, i);
      shift += 7;
      if (shift > 63) return null;
    }
    return null;
  }

  // ── 评论 ────────────────────────────────────────────────

  /// 拉一个视频的评论。type=1 是视频，oid 用 aid（不是 bvid！）。
  /// sort=2 热门，sort=0 时间。
  static Future<BiliReplyPage> fetchReplies(
    String bvid, {
    int page = 1,
    int sort = 2,
  }) async {
    final referer = '$_homeReal/video/$bvid/';
    final aid = await _videoAid(bvid, referer);
    if (aid.isEmpty) return const BiliReplyPage(replies: [], nextPage: null);

    final data = await _getJson(
      '/x/v2/reply',
      query: {
        'type': '1',
        'oid': aid,
        'pn': '$page',
        'ps': '20',
        'sort': '$sort',
      },
      referer: referer,
    );

    final root = data is Map ? data : null;
    final replies = <BiliReply>[];
    if (root?['replies'] is List) {
      for (final item in root!['replies'] as List) {
        if (item is! Map) continue;
        replies.add(_parseReply(item));
      }
    }

    final cursor = root?['cursor'];
    // B站的 is_end 有时是 bool，有时是 int 0/1，还有一种情况是 cursor
    // 干脆不带 is_end（走 next 游标）——这里全部兼容，避免误判成「无更多」。
    final rawEnd = cursor is Map ? cursor['is_end'] : null;
    final rawNext = cursor is Map ? cursor['next'] : null;
    final isEnd = rawEnd == true ||
        rawEnd == 1 ||
        rawEnd == '1' ||
        (rawEnd == null && rawNext is num && rawNext == 0);
    final next = isEnd ? null : page + 1;
    return BiliReplyPage(replies: replies, nextPage: next);
  }

  /// 展开楼中楼：按 root 评论的 rpid 拉全部回复。
  /// 主评论接口默认只带前 3 条，这里按页补全。
  static Future<List<BiliReply>> fetchSubReplies(
    String bvid,
    String rootRpid, {
    int page = 1,
  }) async {
    final referer = '$_homeReal/video/$bvid/';
    final aid = await _videoAid(bvid, referer);
    if (aid.isEmpty) return const [];

    final data = await _getJson(
      '/x/v2/reply/reply',
      query: {
        'type': '1',
        'oid': aid,
        'root': rootRpid,
        'pn': '$page',
        'ps': '10',
      },
      referer: referer,
    );
    final root = data is Map ? data : null;
    final replies = <BiliReply>[];
    if (root?['replies'] is List) {
      for (final item in root!['replies'] as List) {
        if (item is Map) replies.add(_parseReply(item));
      }
    }
    return replies;
  }

  static BiliReply _parseReply(Map item) {
    final member = item['member'];
    final content = item['content'];
    final user = member is Map
        ? (member['uname']?.toString() ?? '')
        : '';
    // B站评论头像在 member.avatar（形如 //i1.hdslb.com/...）。
    // 也兼容 face 字段， normalize 成 https 供 Image.network 直接用。
    final avatarRaw = member is Map
        ? (member['avatar']?.toString() ?? member['face']?.toString() ?? '')
        : '';
    final face = normalizeBiliImage(avatarRaw);
    final message = content is Map
        ? (content['message']?.toString() ?? '')
        : '';
    final like = (item['like'] as num?)?.toInt() ?? 0;
    final timeText = _replyTime(item['ctime']);
    final rcount = (item['rcount'] as num?)?.toInt() ?? 0;
    final subs = <BiliReply>[];
    if (item['replies'] is List) {
      for (final sub in item['replies'] as List) {
        if (sub is Map) subs.add(_parseReply(sub));
      }
    }
    return BiliReply(
      rpid: (item['rpid'] as num?)?.toInt().toString() ?? '',
      user: user,
      message: message,
      like: like,
      timeText: timeText,
      face: face,
      rcount: rcount,
      replies: subs,
    );
  }

  static String _replyTime(dynamic ctime) {
    final ts = (ctime as num?)?.toInt() ?? 0;
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// 发一条评论（type=1 视频，root 楼层）。需要登录 + csrf（bili_jct）。
  static Future<void> postReply(String bvid, String message, {String? parentRpid}) async {
    final session = biliModel.session;
    if (session == null) throw const BiliException('需要登录后才能发评论');
    // 直连时 csrf 在本地 cookie 里；走反代时本地是空的，问服务端要
    var csrf = _csrfOf(session.cookie);
    if (csrf.isEmpty && proxyEnabled) csrf = await proxyCsrf();
    if (csrf.isEmpty) {
      throw const BiliException(
          '这段 Cookie 里没有 bili_jct，B站不接受发送。\n'
          'SESSDATA 只能证明身份，发评论必须带 bili_jct 作为 csrf。'
          '请重新复制完整 Cookie（须同时含 SESSDATA 和 bili_jct）');
    }
    final referer = '$_homeReal/video/$bvid/';
    final aid = await _videoAid(bvid, referer);

    final parentForm = parentRpid == null
        ? <String, String>{}
        : {'root': parentRpid, 'parent': parentRpid};
    final form = <String, String>{
      'oid': aid,
      'type': '1',
      'message': message,
      'csrf': csrf,
      ...parentForm,
    };

    final data = await _postForm(
      '/x/v2/reply/add',
      form: form,
      referer: referer,
    );
    if (data is! Map || (data['code'] as num?)?.toInt() != 0) {
      final code = data is Map ? data['code'] : null;
      throw BiliException('评论发送失败（$code）：${data is Map ? data['message'] : ''}');
    }
  }

  /// 发一条弹幕。需要登录 + csrf。mode=1 滚动，color 默认白色。
  static Future<void> postDanmaku(
    String bvid,
    String text, {
    int mode = 1,
    int color = 0xFFFFFF,
    int progressMs = 0,
  }) async {
    final session = biliModel.session;
    if (session == null) throw const BiliException('需要登录后才能发弹幕');
    // 直连时 csrf 在本地 cookie 里；走反代时本地是空的，问服务端要
    var csrf = _csrfOf(session.cookie);
    if (csrf.isEmpty && proxyEnabled) csrf = await proxyCsrf();
    if (csrf.isEmpty) {
      throw const BiliException(
          '这段 Cookie 里没有 bili_jct，B站不接受发送。\n'
          'SESSDATA 只能证明身份，发送类操作（弹幕/评论/投币）必须带上'
          ' bili_jct 作为 csrf。请重新复制完整 Cookie：'
          '登录B站后打开 DevTools → Network → 任一 api.bilibili.com 请求，'
          '复制请求头里整串 Cookie（必须同时含 SESSDATA 和 bili_jct）');
    }
    final referer = '$_homeReal/video/$bvid/';
    final cid = await _videoCid(bvid, referer);

    final form = <String, String>{
      'type': '1',
      'oid': cid,
      'msg': text,
      'progress': '$progressMs',
      'mode': '$mode',
      'color': '$color',
      'fontsize': '25',
      'pool': '0',
      'plat': '1',
      'csrf': csrf,
      'rnd': '${DateTime.now().millisecondsSinceEpoch}',
    };

    final data = await _postForm(
      '/x/v2/dm/post',
      form: form,
      referer: referer,
    );
    if (data is! Map || (data['code'] as num?)?.toInt() != 0) {
      final code = data is Map ? data['code'] : null;
      throw BiliException('弹幕发送失败（$code）：${data is Map ? data['message'] : ''}');
    }
  }

  /// 从登录 cookie 里抠 csrf（bili_jct）。发评论/弹幕的硬性要求。
  /// 从凭证里取 bili_jct（csrftoken）。
  ///
  /// 必须用 parseCookieInput（按 `;` 分隔的**请求头**格式），不能用
  /// _parseSetCookie —— 后者是为响应头写的，按逗号切多条 Set-Cookie；
  /// 喂给它一条 `a=1; b=2` 的请求头时，整串会被当成一条，
  /// 再取 split(';').first，于是只留下第一个键（buvid3），
  /// bili_jct 永远取不到。
  ///
  /// 这正是「明明贴了完整 Cookie，界面却提示没有 bili_jct」的原因，
  /// 也让桌面端（没有 proxyCsrf 兜底）一直发不了弹幕/评论。
  static String _csrfOf(String cookie) {
    return parseCookieInput(cookie)['bili_jct'] ?? '';
  }

  /// 当前登录凭证里有没有 bili_jct。Cookie 登录时用户很可能只贴了
  /// SESSDATA —— 那样浏览、收藏都正常，唯独发弹幕/评论会被B站拒收。
  /// 设置页用它在登录后立刻给出预警，而不是等到发送时才报错。
  static bool get sessionHasCsrf =>
      _csrfOf(biliModel.session?.cookie ?? '').isNotEmpty;

  /// 视频的 cid。弹幕接口要的是 oid=cid。
  static Future<String> _videoCid(String bvid, String referer) async {
    try {
      final view = await _getJson(
        '/x/web-interface/view',
        query: {'bvid': bvid},
        referer: referer,
      );
      return view is Map ? view['cid']?.toString() ?? '' : '';
    } catch (_) {
      return '';
    }
  }

  /// 视频的 aid。评论接口要的是 oid=aid（不是 bvid）。
  static Future<String> _videoAid(String bvid, String referer) async {
    try {
      final view = await _getJson(
        '/x/web-interface/view',
        query: {'bvid': bvid},
        referer: referer,
      );
      return view is Map ? (view['aid']?.toString() ?? '') : '';
    } catch (_) {
      return '';
    }
  }

  /// 抓B站字幕当歌词用。
  ///
  /// 两个坑，都是踩过才知道的：
  ///
  /// 1. **必须走签名接口 `x/player/wbi/v2`**。未签名的 `x/player/v2`
  ///    不会老实说「这个视频没有字幕」，而是随机吐一份**别的视频**的
  ///    AI 字幕回来 —— 表现就是播放页的歌词和画面完全对不上（一会儿是
  ///    减肥vlog、一会儿是三国的张飞）。签名之后没有字幕就返回空数组。
  /// 2. **字幕列表只有登录后才给**，未登录固定返回空数组，所以没登录时
  ///    这里安静返回空列表，播放页就当这首歌没有歌词。
  ///
  /// 字幕文件是 json：`{body:[{from:秒, to:秒, content:"..."}]}`，
  /// 刚好能直接映射成 LRC 那种「时间 → 一句词」。
  static Future<List<LyricLine>> subtitleLines(String bvid) async {
    final referer = '$_homeReal/video/$bvid/';

    try {
      final view = await _getJson(
        '/x/web-interface/view',
        query: {'bvid': bvid},
        referer: referer,
      );
      if (view is! Map) return const [];
      final cid = view['cid']?.toString() ?? '';
      if (cid.isEmpty) return const [];
      final aid = view['aid']?.toString() ?? '';
      final durationMs = ((view['duration'] as num?)?.toInt() ?? 0) * 1000;

      final mixin = await _wbiMixinKey();
      if (mixin == null) return const [];

      final query = wbiSignedQuery({
        if (aid.isNotEmpty) 'aid': aid,
        'bvid': bvid,
        'cid': cid,
      }, mixin);

      final data = await _requestJson('$_api/x/player/wbi/v2?$query', referer: referer);

      final subtitle = data is Map ? data['subtitle'] : null;
      final list = subtitle is Map ? subtitle['subtitles'] : null;
      if (list is! List || list.isEmpty) return const [];

      final picked = _pickSubtitle(list);
      if (picked == null) return const [];

      final raw = normalizeBiliImage(picked['subtitle_url']?.toString() ?? '');
      if (raw.isEmpty) return const [];

      // 字幕文件同样躺在 CDN 上，Web 端直接取会被跨域拦掉（没有 CORS 头），
      // 所以和音视频一样过一遍反代；没配反代时 _mediaUrls 会原样返回。
      final url = _mediaUrls(bvid, [raw], 'json');

      final res = await _client
          .get(Uri.parse(url), headers: _headers(referer: referer))
          .timeout(_timeout);
      if (res.statusCode != 200) return const [];

      final json = jsonDecode(utf8.decode(res.bodyBytes));
      final body = json is Map ? json['body'] : null;
      if (body is! List) return const [];

      final lines = <LyricLine>[];
      for (final item in body) {
        if (item is! Map) continue;
        final content = sanitizeBiliText(item['content']?.toString() ?? '');
        if (content.isEmpty) continue;
        final from = (item['from'] as num?)?.toDouble() ?? 0;
        lines.add(
          LyricLine(Duration(milliseconds: (from * 1000).round()), content),
        );
      }
      lines.sort((a, b) => a.time.compareTo(b.time));
      if (lines.isEmpty) return const [];

      // 最后一道闸：字幕的时间轴必须落在视频时长内。
      // 签名接口已经不会再串台了，但B站的 AI 字幕偶尔会带着上一版的时间轴，
      // 一条六分钟的字幕配一分钟的视频照样是「错位」。
      if (durationMs > 0) {
        final limit = durationMs + 120000;
        if (lines.last.time.inMilliseconds > limit) {
          debugPrint('[bili] 丢弃字幕：末条 ${lines.last.time.inSeconds}s 超出视频 ${durationMs ~/ 1000}s');
          return const [];
        }
      }
      return lines;
    } catch (e) {
      // 字幕是锦上添花，任何一步失败都不该影响播放
      debugPrint('[bili] 字幕获取失败 $bvid: $e');
      return const [];
    }
  }

  /// WBI 的混淆表。B站把两个 img key 按这个顺序打乱，取前 32 位当签名密钥。
  ///
  /// 这是一张固定表，不是随机数：官方 web 端里就是这些下标。
  static const _mixinKeyEncTab = <int>[
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
  ];

  static String? _wbiMixin;
  static DateTime _wbiAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 取（并缓存）当前账号的 wbi 密钥。
  ///
  /// 密钥来自 `nav` 里的两张图，一天才换一次，所以缓存 6 小时足够，
  /// 免得每取一次字幕都多打一个接口。
  static Future<String?> _wbiMixinKey() async {
    final now = DateTime.now();
    if (_wbiMixin != null && now.difference(_wbiAt) < const Duration(hours: 6)) {
      return _wbiMixin;
    }
    try {
      final nav = await _getJson('/x/web-interface/nav');
      final wbi = nav is Map ? nav['wbi_img'] : null;
      if (wbi is! Map) return null;
      final img = _keyFromWbiUrl(wbi['img_url']?.toString() ?? '');
      final sub = _keyFromWbiUrl(wbi['sub_url']?.toString() ?? '');
      if (img.isEmpty || sub.isEmpty) return null;

      final raw = '$img$sub';
      final buf = StringBuffer();
      for (final index in _mixinKeyEncTab) {
        if (index < raw.length) buf.write(raw[index]);
        if (buf.length >= 32) break;
      }
      if (buf.length < 32) return null;
      _wbiMixin = buf.toString();
      _wbiAt = now;
      return _wbiMixin;
    } catch (_) {
      return null;
    }
  }

  /// `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`
  /// → `7cd084941338484aae1ad9425b84077c`
  static String _keyFromWbiUrl(String url) {
    final name = url.split('/').last;
    final dot = name.indexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 算出一串带 `w_rid` 的查询串。
  ///
  /// 规则（和官方 web 端一致）：去掉值里的 `!'()*`、按 key 排序、
  /// 拼上 `wts`、再 md5(查询串 + 密钥)。对测试开放是因为签名错了只会
  /// 表现为「拿不到字幕」，不给一条能对账的向量就只能瞎猜。
  static String wbiSignedQuery(
    Map<String, String> params,
    String mixinKey, {
    int? wts,
  }) {
    final all = <String, String>{
      for (final entry in params.entries)
        entry.key: entry.value.replaceAll(RegExp(r"[!'()*]"), ''),
      'wts': '${wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };
    final keys = all.keys.toList()..sort();
    final query = keys
        .map((k) => '${Uri.encodeQueryComponent(k)}='
            '${Uri.encodeQueryComponent(all[k]!)}')
        .join('&');
    final rid = md5.convert(utf8.encode('$query$mixinKey')).toString();
    return '$query&w_rid=$rid';
  }


  /// 多条字幕里挑一条：中文优先，其次是 AI 中文，最后随便拿第一条。
  static Map<String, dynamic>? _pickSubtitle(List raw) {
    final items = raw.whereType<Map>().toList();
    if (items.isEmpty) return null;

    Map? pick;
    for (final item in items) {
      final lan = item['lan']?.toString() ?? '';
      if (lan == 'zh-CN' || lan == 'zh-Hans') {
        pick = item;
        break;
      }
    }
    pick ??= items.firstWhere(
      (item) => (item['lan']?.toString() ?? '').startsWith('ai-zh'),
      orElse: () => items.first,
    );
    return pick.cast<String, dynamic>();
  }

  /// 详情页要的元信息（标题、封面、分P数）。
  /// 搜索结果已经带了大部分字段，只有分P数得现查 —— 目前没用上，
  /// 留着给「打开原视频」之类的入口。
  static Future<BiliVideo?> videoInfo(String bvid) async {
    try {
      final view = await _getJson(
        '/x/web-interface/view',
        query: {'bvid': bvid},
        referer: '$_homeReal/video/$bvid/',
      );
      if (view is! Map) return null;
      return BiliVideo.fromJson({
        'bvid': view['bvid'],
        'aid': view['aid'],
        'title': view['title'],
        'pic': view['pic'],
        'author': view['owner'] is Map ? (view['owner'] as Map)['name'] : '',
        'mid': view['owner'] is Map ? (view['owner'] as Map)['mid'] : 0,
        'duration': view['duration'],
        'pubdate': view['pubdate'],
      });
    } catch (_) {
      return null;
    }
  }

  // ── 登录 ─────────────────────────────────────────────────

  /// 第一步：拿二维码。
  static Future<BiliQrCode> createQrCode() async {
    final data = await _getJson(
      '/x/passport-login/web/qrcode/generate',
      host: _passport,
      referer: '$_homeReal/',
    );
    final url = data is Map ? data['url']?.toString() ?? '' : '';
    final key = data is Map ? data['qrcode_key']?.toString() ?? '' : '';
    if (url.isEmpty || key.isEmpty) {
      throw const BiliException('登录二维码生成失败，请稍后再试');
    }
    return BiliQrCode(url: url, key: key);
  }

  /// 第二步：轮询扫码结果。界面每 2 秒调一次。
  static Future<BiliLoginStatus> pollQrCode(String key) async {
    final uri = Uri.parse('$_passport/x/passport-login/web/qrcode/poll')
        .replace(queryParameters: {'qrcode_key': key});

    // 扫码成功后凭证有两个可能的落点：data.url 的查询参数，或者 Set-Cookie。
    // B站按账号分组走不同的路，所以响应头要留一份下来。
    final headers = <String, String>{};
    final data = await _requestJson(
      uri.toString(),
      referer: '$_homeReal/',
      headerSink: headers,
    );

    if (data is! Map) {
      return const BiliLoginStatus(code: -1, message: '扫码信号读取失败');
    }

    final code = (data['code'] as num?)?.toInt() ?? -1;

    if (code != 0) {
      return BiliLoginStatus(code: code, message: _loginMessage(code));
    }

    // 成功时 data.url 里带着一整套 cookie 参数，比解析 Set-Cookie 可靠
    final url = data['url']?.toString() ?? '';
    var jar = _cookiesFromLoginUrl(url);

    // 有些账号的 url 是空的，凭证只出现在 Set-Cookie 里（桌面端读得到，
    // 浏览器读不到 —— 浏览器那边由反代收进服务端会话，见下面的兜底）
    if ((jar['SESSDATA'] ?? '').isEmpty) {
      final fromHeader = _parseSetCookie(headers['set-cookie']);
      if ((fromHeader['SESSDATA'] ?? '').isNotEmpty) jar = fromHeader;
    }

    if ((jar['SESSDATA'] ?? '').isEmpty) {
      // 走反代时凭证已经落在服务端会话里，客户端手上没有也不要紧：
      // 带着当前会话问一句「我是谁」就能确认，不必让用户再扫一遍
      if (proxyEnabled) {
        final session = await _fetchAccount('');
        if (session != null) {
          return BiliLoginStatus(code: 0, message: '登录成功，欢迎回来，博士', session: session);
        }
      }
      return const BiliLoginStatus(
        code: -1,
        message: '扫码已确认，但对方未交还凭证。\n可改用『用 Cookie 登录』通道',
      );
    }

    final cookie = _mergeCookie(_guestCookie, jar);
    final session = await _fetchAccount(cookie);
    if (session == null) {
      return const BiliLoginStatus(code: -1, message: '登录成功，但未能读取账号信息');
    }
    return BiliLoginStatus(code: 0, message: '登录成功，欢迎回来，博士', session: session);
  }

  /// 用粘贴的凭证登录。
  ///
  /// 这是扫码之外的备用路径：不经过B站的登录接口，所以既没有验证码，
  /// 也没有短信和设备风控，扫码一直卡在「已扫码但确认失败」时用它最省事。
  ///
  /// 只认 SESSDATA，其余键有就一起带上（bili_jct 是收藏、投币要用的 csrf）。
  /// 拿到之后一定用 nav 验一次真假：B站说 isLogin=true 才写进登录态，
  /// 粘错、过期都会当场报错 —— 不允许出现「界面显示已登录、请求却是匿名」的状态。
  static Future<BiliSession> loginWithCookie(String raw) async {
    final jar = parseCookieInput(raw);
    if ((jar['SESSDATA'] ?? '').isEmpty) {
      throw const BiliException('未能辨识出 SESSDATA。请粘贴完整 Cookie，或只粘贴它的值');
    }

    if (kIsWeb && !proxyEnabled) {
      // 网页里设置 Cookie 头是被浏览器直接丢掉的，没有反代这条路走不通，
      // 与其让它静默失败，不如说清楚要先配哪个东西
      throw const BiliException('网页端要经『接口反代』才能登录，浏览器不让页面自带 Cookie');
    }

    final cookie = _mergeCookie(_guestCookie, jar);

    if (proxyEnabled) {
      // 真正附在请求上的是服务端手上那份：得先把凭证交过去，再发 nav 才有意义
      if (!await ensureSession()) {
        throw const BiliException('登录没成，去设置里核对下反代地址');
      }
      final mid = int.tryParse(jar['DedeUserID'] ?? '') ?? 0;
      if (!await importSession(cookie: cookie, mid: mid)) {
        throw const BiliException('反代没能从这段 Cookie 里认出 SESSDATA');
      }
    }

    final session = await _fetchAccount(cookie);
    if (session == null) {
      throw const BiliException('凭证已失效（对方判定为未登录）。请重新获取后再试，博士');
    }

    await biliModel.setSession(session);
    _audioCache.clear();
    return session;
  }

  /// 解析粘贴进来的凭证文本。
  ///
  /// 对测试开放：界面不该自己再写一遍解析，两边规则一错开就会出现
  /// 「界面说格式对了、请求却拿不到 key」这种最难查的 bug。
  ///
  /// 认这几种形态：
  ///   1. `SESSDATA=xxx; bili_jct=yyy; DedeUserID=zzz`
  ///   2. 只有 SESSDATA 的值（一长串带 `%2C` 的字符）
  ///   3. 从 cookie 面板整行复制的，带 `Path=/` `Expires=..` 这些属性
  ///   4. 扫码成功后跳转的 crossDomain URL
  ///   5. 浏览器插件导出的 JSON
  static Map<String, String> parseCookieInput(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return {};
    // 从 DevTools 复制常带着 `Cookie:` 前缀，先摘掉，否则 `"SESSDATA` 会被当成键名
    text = text
        .replaceFirst(RegExp(r'^cookie\s*:\s*', caseSensitive: false), '')
        .trim();
    // 再去掉粘贴时包上的引号、反引号
    text = text.replaceAll(RegExp(r'''^[`"']+|[`"']+$'''), '').trim();
    if (text.isEmpty) return {};

    // 形态四：登录跳转地址
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final jar = _cookiesFromLoginUrl(text);
      if (jar.isNotEmpty) return jar;
    }

    // 形态五：JSON
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final jar = <String, String>{};
          decoded.forEach((k, v) {
            if (v is String && v.isNotEmpty) jar[k.toString()] = v;
          });
          if (jar.containsKey('SESSDATA')) return jar;
          // 插件常见的包装：{"cookie": "SESSDATA=..; bili_jct=.."}
          final nested = jar['cookie'];
          if (nested != null && nested.isNotEmpty) return parseCookieInput(nested);
        }
      } catch (_) {
        // 不是合法 JSON 就当成 cookie 串继续往下走
      }
    }

    // 形态二：只有一个值，没有 `name=`
    if (!text.contains('=')) {
      if (text.length >= 16 && !text.contains(' ')) return {'SESSDATA': text};
      return {};
    }

    // 形态一 / 三：按 `;` 或换行切
    final jar = <String, String>{};
    for (final part in text.split(RegExp(r'[;\n]'))) {
      final piece = part.trim();
      if (piece.isEmpty) continue;
      final eq = piece.indexOf('=');
      if (eq <= 0) continue;
      final name = piece.substring(0, eq).trim();
      final value = piece.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      if (name.contains(' ')) continue;
      // `Path=/` `Expires=..` 这些是属性，不是凭证
      if (_cookieAttr.contains(name.toLowerCase())) continue;
      jar[name] = value;
    }
    return jar;
  }

  static String _loginMessage(int code) {    switch (code) {
      case 86101:
        return '等待扫码登录…';
      case 86090:
        return '已读取扫码信号，等待终端确认';
      case 86038:
        return '凭证已过期，将自动换发新的二维码';
      default:
        return '扫码状态：$code';
    }
  }

  /// 带着 cookie 问一次「我是谁」。登录后回填昵称和头像要用。
  static Future<BiliSession?> _fetchAccount(String cookie) async {
    try {
      final data = await _getJson(
        '/x/web-interface/nav',
        cookieOverride: cookie,
      );
      if (data is! Map || data['isLogin'] != true) return null;
      return BiliSession(
        mid: (data['mid'] as num?)?.toInt() ?? 0,
        name: data['uname']?.toString() ?? 'B站用户',
        face: normalizeBiliImage(data['face']?.toString() ?? ''),
        cookie: cookie,
      );
    } catch (_) {
      return null;
    }
  }

  /// 退出登录。
  ///
  /// 走反代时还要让服务端把那份凭证也丢掉 —— 否则重新打开页面，
  /// 服务端的会话里 SESSDATA 还在，表现为「明明退出了却还是登录状态」。
  static Future<void> logout() async {
    if (proxyEnabled) {
      try {
        await _client
            .delete(
              Uri.parse('$_proxyBase/bili/session'),
              headers: _sid == null ? null : {'X-Session': _sid!},
            )
            .timeout(_timeout);
      } catch (_) {
        // 服务端清不掉也不该挡住本地登出
      }
    }
    await biliModel.setSession(null);
    _audioCache.clear();
  }

  // ── cookie 小工具 ────────────────────────────────────────

  /// 解析 Set-Cookie。多个 cookie 用 ", " 连在一起，但 Expires 里也有逗号，
  /// 所以只认「第一段是 name=value 且 name 不含空格」的。
  static Map<String, String> _parseSetCookie(String? raw) {
    final jar = <String, String>{};
    if (raw == null || raw.isEmpty) return jar;

    const skip = {'expires', 'path', 'domain', 'max-age', 'samesite', 'secure',
      'httponly', 'priority', 'version', 'comment'};

    for (final segment in raw.split(RegExp(r',(?=\s*[A-Za-z_][A-Za-z0-9_\-]*=)'))) {
      final first = segment.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final name = first.substring(0, eq).trim();
      if (name.contains(' ') || skip.contains(name.toLowerCase())) continue;
      jar[name] = first.substring(eq + 1).trim();
    }
    return jar;
  }

  /// 登录成功时 data.url 形如
  /// `https://passport.biligame.com/crossDomain?DedeUserID=..&SESSDATA=..&bili_jct=..`
  /// 值本身是 URL 编码的，要原样保留（SESSDATA 里有 %2C）。
  static Map<String, String> _cookiesFromLoginUrl(String url) {
    final jar = <String, String>{};
    final start = url.indexOf('?');
    if (start < 0) return jar;

    for (final pair in url.substring(start + 1).split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq);
      final value = pair.substring(eq + 1);
      // 只留真正用来鉴权的四个，gourl / Expires 这些带过去没意义
      if (name == 'SESSDATA' ||
          name == 'bili_jct' ||
          name == 'DedeUserID' ||
          name == 'DedeUserID__ckMd5') {
        if (value.isNotEmpty) jar[name] = value;
      }
    }
    return jar;
  }

  static String _mergeCookie(String? base, Map<String, String> extra) {
    final jar = <String, String>{};

    void absorb(String? raw) {
      if (raw == null) return;
      for (final pair in raw.split(';')) {
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        jar[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
    }

    absorb(base);
    jar.addAll(extra);
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}

class _CachedUrl {
  const _CachedUrl(this.urls, this.expiresAt);

  final List<String> urls;
  final DateTime expiresAt;
}
