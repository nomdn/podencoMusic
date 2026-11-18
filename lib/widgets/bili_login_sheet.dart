import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../bili_api.dart';
import '../bili_store.dart';

/// 扫码登录哔哩哔哩。
///
/// 走的是 B站网页版的二维码登录：生成 → 手机扫码 → 手机确认 → 回调里
/// 带着一整套 cookie。cookie 以明文存在本机，和浏览器保存登录态是
/// 同一性质，所以弹层里把这件事写清楚，并连着「退出登录」一起给。
Future<bool> showBiliLoginSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _LoginSheet(),
  );
  return ok ?? false;
}

class _LoginSheet extends StatefulWidget {
  const _LoginSheet();

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  BiliQrCode? _qr;
  String _status = '正在建立登录通讯…';
  bool _failed = false;
  Timer? _poll;

  /// 切到「粘贴 Cookie」这条备用路径
  bool _cookieMode = false;
  bool _submitting = false;
  String? _cookieError;
  final _cookieCtrl = TextEditingController();

  /// 正在换新二维码。防止「过期」在连着的两轮轮询里被处理两次。
  bool _refreshing = false;

  /// 当前二维码的生成时间与上一次轮询码，用于「还没扫但快到期」时提前换一张。
  DateTime? _qrAt;
  int _lastCode = -1;

  /// 连续轮询失败次数。反代挂了的时候会一直静默轮询，
  /// 界面却写着「用手机扫一扫」，用户只能干等 —— 攒够几次就把原因摆出来。
  int _pollErrors = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _cookieCtrl.dispose();
    super.dispose();
  }

  /// 提交粘贴的凭证。成功才关弹层，失败把原因留在原地。
  Future<void> _submitCookie() async {
    final raw = _cookieCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _cookieError = '请先粘贴 Cookie');
      return;
    }

    setState(() {
      _submitting = true;
      _cookieError = null;
    });

    try {
      await BiliApi.loginWithCookie(raw);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _cookieError = e is BiliException ? e.message : '登录失败：$e';
      });
    }
  }

  Future<void> _start({String? note}) async {
    _poll?.cancel();
    _lastCode = -1;
    setState(() {
      _qr = null;
      _qrAt = null;
      _failed = false;
      _status = note ?? '正在建立登录通讯…';
    });

    try {
      final qr = await BiliApi.createQrCode();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _qrAt = DateTime.now();
        _status = '请使用『哔哩哔哩』客户端扫描，博士';
      });
      _startPolling(qr.key);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = e is BiliException ? e.message : '二维码生成失败：$e';
      });
    }
  }

  void _startPolling(String key) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final status = await BiliApi.pollQrCode(key);
        if (!mounted) {
          timer.cancel();
          return;
        }
        _pollErrors = 0;
        _lastCode = status.code;

        // 还没扫、码又快到 3 分钟有效期了，就提前换一张。
        // 只看「未扫码」这个状态：用户已经在手机上点了确认（86090）时
        // 绝不能换码，否则那一轮确认就白点了。
        final age = _qrAt == null ? 0 : DateTime.now().difference(_qrAt!).inSeconds;
        if (age >= 150 && _lastCode == 86101 && !_refreshing) {
          timer.cancel();
          unawaited(_autoRefresh());
          return;
        }

        if (status.done) {
          timer.cancel();
          await biliModel.setSession(status.session);
          if (!mounted) return;
          Navigator.of(context).pop(true);
          return;
        }

        setState(() => _status = status.message);
        if (status.expired) {
          // 二维码三分钟就过期，弹层开着不动是很常见的情况。
          // 过期了直接换一张，别让用户对着「刷新二维码」按钮来回点。
          timer.cancel();
          unawaited(_autoRefresh());
        }
      } catch (e) {
        // 轮询失败（网络抖）不终止，下一轮继续；但一直失败要说出来
        _pollErrors++;
        if (mounted && _pollErrors == 5 && !_cookieMode) {
          setState(() {
            _failed = true;
            _status = '扫码信号读取失败：${e is BiliException ? e.message : e}';
          });
        }
      }
    });
  }

  /// 二维码快到期 / 已到期后自动换一张。成功换到就继续轮询，失败就把原因留在界面上。
  Future<void> _autoRefresh() async {
    if (_refreshing || !mounted) return;
    _refreshing = true;
    try {
      await _start(note: '正在换发新的二维码…');
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qr = _qr;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.qr_code_2, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('登录哔哩哔哩', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 16),
              if (qr != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: QrImageView(
                    data: qr.url,
                    size: 200,
                    // 二维码必须在浅底上，深色主题下不铺白底会扫不出来
                    backgroundColor: Colors.white,
                  ),
                )
              else
                const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                ),
              const SizedBox(height: 16),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '登录二维码三分钟内有效，无人扫描将自动换发；\n'
                '账号档案仅保存在本机，用于检索、观影与收藏；'
                '随时可在设置中退出登录。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新二维码'),
              ),
              const Divider(height: 24),
              if (!_cookieMode)
                TextButton.icon(
                  onPressed: () => setState(() => _cookieMode = true),
                  icon: const Icon(Icons.key),
                  label: const Text('手机不在身边？用 Cookie 登录'),
                )
              else
                _buildCookieForm(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Cookie 登录表单。
  ///
  /// 定位是备用路径，所以放在二维码下面而不是做成两个 Tab —— 大多数人
  /// 还是扫码，这里只需要「找得到、说得清怎么拿」。
  Widget _buildCookieForm(ThemeData theme) {
    final blockedOnWeb = kIsWeb && !BiliApi.proxyEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.key, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('用 Cookie 登录', style: theme.textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: '收起',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _cookieMode = false;
                _cookieError = null;
              }),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _cookieCtrl,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText: 'SESSDATA=xxxx%2C1794801182%2Cabcd…',
            helperText: '完整 Cookie 或单独的 SESSDATA 值均可',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '获取方式：浏览器登录 bilibili.com → F12 → Application → '
          'Cookies → bilibili.com → 复制 SESSDATA 的值即可。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (blockedOnWeb) ...[
          const SizedBox(height: 8),
          Text(
            '网页端登录须经『接口反代』：浏览器不允许页面自带 Cookie 头，'
            '缺少中转无法完成登录。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              height: 1.5,
            ),
          ),
        ],
        if (_cookieError != null) ...[
          const SizedBox(height: 8),
          Text(
            _cookieError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (_submitting || blockedOnWeb) ? null : _submitCookie,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('用这段 Cookie 登录'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Cookie 仅写入本机（启用反代时交由它代持），等同于浏览器的登录态，请勿外泄。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
