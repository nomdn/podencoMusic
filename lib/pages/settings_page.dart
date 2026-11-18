import 'package:material_ui/material_ui.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../bili_api.dart';
import '../bili_store.dart';
import '../downloader.dart';
import '../music_store.dart';
import '../siren_api.dart';
import '../storage.dart';
import '../storage_usage.dart';
import '../widgets/bili_login_sheet.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player.dart';

/// 设置页。目前只有一项：接口代理地址。
///
/// 塞壬 API 域名有 CORS 限制，Web 端想正常工作需要自建反代
/// （与官方 API 同路径同定义、只转发流量），把反代地址填在这里即可。
/// 封面、音频、歌词在鹰角 OSS 上（响应带 CORS 允许头），直连，不走代理。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _controller =
      TextEditingController(text: SirenApi.host == SirenApi.defaultHost ? '' : SirenApi.host);
  bool _usingCustom = SirenApi.host != SirenApi.defaultHost;

  // ── vivo 原子随身听白名单 ──
  late final bool _vivoSupported = MusicStore.isSupported;
  bool _vivoLoaded = false;
  bool _vivoAvailable = false;
  bool _vivoBusy = false;
  List<String>? _vivoList;

  bool get _vivoInList =>
      _vivoList?.contains(MusicStore.appPackage) ?? false;

  // ── 存储占用 ──
  StorageUsage? _storage;
  bool _storageLoaded = false;
  bool _storageBusy = false;

  @override
  void initState() {
    super.initState();
    // Web 上没有本地目录可统计，连读取都省了
    if (!kIsWeb) unawaited(_loadStorage());
    if (_vivoSupported) unawaited(_loadVivoWhitelist());
  }

  /// 反代那一行的副标题。三种状态要能一眼分清：
  /// 没配、配了且通、配了但连不上（此时其实在直连）。
  String _proxySummary() {
    if (biliModel.proxy.isEmpty) return '没填地址 · 直接连B站';
    if (biliModel.proxyActive) return '${biliModel.proxy} · 通道正常';
    return '${biliModel.proxy} · 连不上，暂时直连';
  }

  Future<void> _editProxy(BuildContext context) async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _ProxyDialog(initial: biliModel.proxy),
    );
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadStorage() async {
    final usage = await StorageUsage.read();
    if (!mounted) return;
    setState(() {
      _storage = usage;
      _storageLoaded = true;
    });
  }

  /// 清理后重新统计，数字要跟着变，不能留着旧值骗人
  Future<void> _runClear(Future<int> Function() clear) async {
    if (_storageBusy) return;
    setState(() => _storageBusy = true);
    try {
      final removed = await clear();
      if (!mounted) return;
      await _loadStorage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清理 $removed 份缓存档案')),
      );
    } finally {
      if (mounted) setState(() => _storageBusy = false);
    }
  }

  Future<void> _loadVivoWhitelist() async {
    final raw = await MusicStore.vivoWhitelist();
    if (!mounted) return;
    setState(() {
      _vivoAvailable = raw != null;
      _vivoList = MusicStore.parseWhitelist(raw);
      _vivoLoaded = true;
    });
  }

  Future<void> _save(String value) async {
    final v = value.trim();
    if (v.isNotEmpty && !v.startsWith('http://') && !v.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址要以 http:// 或 https:// 开头')),
      );
      return;
    }

    // 契约：反代与官方 API 同路径（含 /api 前缀）—— 只填根地址时自动补上，
    // 避免「配了代理但请求 404」的坑
    var host = v;
    if (host.isNotEmpty && !host.endsWith('/api')) {
      host = host.endsWith('/') ? '${host.substring(0, host.length - 1)}/api' : '$host/api';
    }

    await ApiConfigStorage.save(host);
    SirenApi.host = host;
    if (!mounted) return;
    setState(() => _usingCustom = host.isNotEmpty);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(host.isEmpty ? '已恢复默认接口' : '已保存，当前接口：$host')),
    );
  }

  // ── vivo 原子随身听白名单：加白 / 移出 ─────────────────────

  Future<void> _joinVivoWhitelist() async {
    final list0 = _vivoList;
    if (list0 == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final env = await MusicStore.vivoWhitelistEnv();
    if (!mounted) return;
    if (env == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('通道环境读取失败，可点「ADB 手动命令」手动添加')),
      );
      return;
    }
    var ready = env.shizukuReady;

    // Shizuku 在运行但还没授权：拉起它的授权框，点了允许就直接就绪
    if (!ready && env.shizukuAlive) {
      ready = await MusicStore.vivoShizukuRequestPermission();
      if (!mounted) return;
      if (!ready) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Shizuku 没给授权，改用「修改系统设置」方式'),
        ));
      }
    }

    // 没有 Shizuku：需要「修改系统设置」授权，跳系统页让用户打开
    if (!ready && !env.canWriteSettings) {
      await MusicStore.openVivoWriteSettings();
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('请先在系统设置里允许「修改系统设置」，再回来点一次加入'),
      ));
      return;
    }

    setState(() => _vivoBusy = true);
    final list = MusicStore.whitelistWith(list0, MusicStore.appPackage);
    final ok =
        await MusicStore.setVivoWhitelist(MusicStore.serializeWhitelist(list));
    if (!mounted) return;
    setState(() {
      _vivoBusy = false;
      if (ok) _vivoList = list;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? '已加入白名单（${ready ? 'Shizuku' : '修改系统设置'}）。'
              'OriginOS 4 上暂停再播放即可看到胶囊；5+ 未出现属系统层限制'
          : '写入失败：可点「ADB 手动命令」查看手动步骤'),
    ));
  }

  Future<void> _leaveVivoWhitelist() async {
    final list0 = _vivoList;
    if (list0 == null) return;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _vivoBusy = true);
    final list = MusicStore.whitelistWithout(list0, MusicStore.appPackage);
    final ok =
        await MusicStore.setVivoWhitelist(MusicStore.serializeWhitelist(list));
    if (!mounted) return;
    setState(() {
      _vivoBusy = false;
      if (ok) _vivoList = list;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? '已移出，原子随身听不再显示本应用'
          : '写入失败：可点「ADB 手动命令」查看手动步骤'),
    ));
  }

  /// ADB 手动加白说明。应用内双通道都失败时的兜底路径；
  /// 命令按当前白名单实时生成，复制即可执行。
  void _showAdbHelp() {
    final key = MusicStore.vivoWhitelistKey;
    final pkg = MusicStore.appPackage;
    final list = _vivoList;
    final putCommand = list == null
        ? 'adb shell settings put system $key \'["步骤1返回的原值","$pkg"]\''
        : "adb shell settings put system $key "
            "'${MusicStore.serializeWhitelist(MusicStore.whitelistWith(list, pkg))}'";
    final theme = Theme.of(context);

    unawaited(showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ADB 手动加白'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '应用内写入失败时的兜底：电脑连手机按顺序执行。'
                'JSON 整段不能有空格；Windows 终端注意引号转义。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Text('1. 查看当前白名单（先备份原值）'),
              SelectableText('adb shell settings get system $key',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              const Text('2. 把本应用追加进原值末尾'),
              SelectableText(putCommand, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              const Text('3. 恢复默认（清空全部自定义条目，慎用）'),
              SelectableText("adb shell settings put system $key '[]'",
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('接口代理', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '网页版受浏览器跨域限制（CORS），无法直接访问官方接口，'
            '因此内置了一个默认代理地址，留空即可正常使用；'
            '桌面版和安卓版没有这个限制，默认直连官方接口，一般无需修改。\n'
            '如果默认代理失效，或你想用自己的代理，填入新地址并保存即可。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: '代理地址（填根地址即可，自动补 /api）',
              hintText: '留空使用默认接口',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: _save,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _save(_controller.text),
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _controller.clear();
                  unawaited(_save(''));
                },
                icon: const Icon(Icons.restart_alt),
                label: const Text('恢复默认'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _usingCustom
                ? '当前接口：${SirenApi.host}'
                : '当前接口：默认（${SirenApi.defaultHost}）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '封面、音频、歌词始终由应用直接下载，不经过代理；'
            '代理只影响专辑列表、歌曲信息等接口请求。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Text('哔哩哔哩数据源', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '开启后，检索终端会多出「B站」与「UP主」两个来源，可与塞壬并列；'
            'B站影像也能编入同一歌单，与塞壬音轨混播。\n'
            '不登录也能检索，但未登录请求易遭风控，登录后更稳。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 6),
            Text(
              '网页端受限：B站会拒绝带 Origin 头的请求（实测 412/403），'
              '浏览器又不允许设置 Referer / Cookie，'
              '所以检索、播放、登录在哪一步都过不去。启用B站源需自建代理。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 4),
          ListenableBuilder(
            listenable: biliModel,
            builder: (context, _) {
              final session = biliModel.session;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 网页版没有可用反代时，下面所有按钮点下去都必然失败，
                  // 与其让人一个个试，不如这里直接说清楚拦在哪。
                  // 默认地址是随包发的，所以这里出现只说明它当前连不通。
                  if (kIsWeb && !biliModel.proxyActive) ...[
                    Text(
                      '网页端的B站内容全靠『接口反代』中转。现在这个地址连不上，'
                      '可以在下面换成你自己的。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用B站搜索'),
                    subtitle: Text(
                      biliModel.enabled
                          ? '已启用，检索终端可切换至B站来源'
                          : '已关闭，检索终端仅检索塞壬档案',
                    ),
                    value: biliModel.enabled,
                    onChanged: (value) => biliModel.setEnabled(value),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ClipOval(
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: session == null
                            ? Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.person,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : CoverImage(url: session.face),
                      ),
                    ),
                    title: Text(session?.name ?? '未登录B站'),
                    subtitle: Text(
                      session == null
                          ? kIsWeb && !biliModel.proxyActive
                                ? '反代连不上，网页端暂时登不了'
                                : '扫码登录你自己的B站账号'
                          : '已登录 · UID ${session.mid}',
                    ),
                    // 网页版的登录同样卡在跨域上（passport 也拦 Origin），
                    // 配了反代之后这条路就通了 —— 二维码和轮询都由服务端转发
                    trailing: kIsWeb && !biliModel.proxyActive
                        ? null
                        : session == null
                        ? FilledButton.tonal(
                            onPressed: () async {
                              final ok = await showBiliLoginSheet(context);
                              if (!context.mounted || !ok) return;
                              // Cookie 登录时用户常只贴 SESSDATA —— 登录是
                              // 成功的，但发弹幕/评论会被B站拒收（缺 bili_jct
                              // 作为 csrf）。趁登录的余温立刻预警，别让用户
                              // 等到发送失败才明白。
                              final csrfTip = BiliApi.sessionHasCsrf
                                  ? ''
                                  : '\n⚠ 这份 Cookie 里没有 bili_jct，发弹幕/评论将被拒收。请重新复制完整 Cookie（含 SESSDATA 和 bili_jct）';
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '欢迎回来，Dr.${biliModel.session?.name ?? ''}$csrfTip',
                                    style: TextStyle(
                                      color: BiliApi.sessionHasCsrf
                                          ? null
                                          : Theme.of(context)
                                              .colorScheme
                                              .error,
                                    ),
                                  ),
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            },
                            child: const Text('扫码登录'),
                          )
                        : TextButton(
                            onPressed: () async {
                              await BiliApi.logout();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已退出B站账号')),
                              );
                            },
                            child: const Text('退出登录'),
                          ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('接口反代'),
                    subtitle: Text(_proxySummary()),
                    trailing: TextButton(
                      onPressed: () => _editProxy(context),
                      child: Text(biliModel.proxy.isEmpty ? '配置' : '修改'),
                    ),
                  ),
                ],
              );
            },
          ),
          // 存储管理只在原生平台有意义：Web 上没有本地文件系统，
          // 封面走浏览器 HTTP 缓存、下载走 File System Access 写进用户自选目录，
          // 应用既读不到也清不了，摆一排 0 只会让人以为坏了。
          if (!kIsWeb) ...[
            const SizedBox(height: 24),
            Text('存储', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '封面和歌词都是可以随时重建的缓存，清掉只是下次加载慢一点；'
              '歌单、播放历史和播放进度存在应用数据里，这里不会动它们。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            if (!_storageLoaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.image_outlined),
                title: const Text('封面与歌词缓存'),
                subtitle: Text(
                  '${StorageUsage.format(_storage!.cacheBytes)} · '
                  '${_storage!.cacheCount} 个文件',
                ),
                trailing: TextButton(
                  onPressed: _storageBusy || _storage!.cacheCount == 0
                      ? null
                      : () => unawaited(_runClear(StorageUsage.clearCache)),
                  child: const Text('清理'),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.download_outlined),
                title: const Text('已下载的音乐'),
                subtitle: Text(
                  _storage!.downloadKnown
                      ? '${StorageUsage.format(_storage!.downloadBytes)} · '
                            '${_storage!.downloadCount} 个文件'
                      : '由系统音乐库管理（Music/PodencoMusic）',
                ),
                trailing: TextButton.icon(
                  onPressed: () => unawaited(downloader.openFolder()),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('打开'),
                ),
              ),
            ],
          ],
          if (_vivoSupported) ...[
            const SizedBox(height: 24),
            Text('vivo 原子随身听', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'vivo / iQOO 挖孔播放胶囊的白名单开关。OriginOS 4 上加入后'
              '播放时挖孔旁会出现胶囊；OriginOS 5 起系统在代码层另有厂商'
              '白名单（酷狗 / QQ音乐 / 网易云等），写入后不保证生效，'
              '通知栏媒体通知不受影响。装了 Shizuku 就优先用它（推荐），'
              '否则需授予「修改系统设置」权限；可随时移出还原。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            if (!_vivoLoaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (!_vivoAvailable)
              Text(
                '未检测到白名单：仅 OriginOS 4 支持；'
                '若新版系统已官方开放音源，无需在此配置。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              Text(
                _vivoInList ? '当前状态：已在白名单中' : '当前状态：未加入',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  if (_vivoInList)
                    OutlinedButton.icon(
                      onPressed: _vivoBusy ? null : _leaveVivoWhitelist,
                      icon: const Icon(Icons.remove_circle_outline),
                      label: const Text('移出白名单'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _vivoBusy ? null : _joinVivoWhitelist,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('加入白名单'),
                    ),
                  TextButton.icon(
                    onPressed: _vivoBusy ? null : _showAdbHelp,
                    icon: const Icon(Icons.terminal),
                    label: const Text('ADB 手动命令'),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}

/// 反代地址的编辑弹窗。
///
/// 单独做成有状态组件，是为了「测试」能在不关弹窗的前提下显示结果 ——
/// 地址常被填错一位，让人反复关开太折磨。
class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.initial});

  final String initial;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  /// 测试通过时让对勾弹一下。和登录弹层的成功反馈同一套语言，
  /// 但这里是内联反馈 —— 用户还在填地址，不能自作主张关掉对话框。
  late final AnimationController _okAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final Animation<double> _okScale = CurvedAnimation(
    parent: _okAnim,
    curve: Curves.elasticOut,
  );

  bool _busy = false;
  String? _hint;
  bool _hintOk = false;

  @override
  void dispose() {
    _okAnim.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _hint = null;
      _hintOk = false;
    });
    final result = await BiliApi.probeProxy(_controller.text);
    if (!mounted) return;
    final ok = result.startsWith(BiliApi.probeOkPrefix);
    setState(() {
      _busy = false;
      _hint = result;
      _hintOk = ok;
    });
    if (ok) {
      // 连续点两次「测试」也要重播，所以先 reset
      unawaited(_okAnim.forward(from: 0));
    }
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    setState(() {
      _busy = true;
      _hint = null;
    });

    // 清空等于关闭反代，这条不需要联网验证
    if (value.isEmpty) {
      await biliModel.setProxy('');
      if (!mounted) return;
      Navigator.of(context).pop('反代已关掉 · 回到直连B站');
      return;
    }

    final ok = await biliModel.setProxy(value);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _hint = '这个地址连不上，配置未保存';
        _hintOk = false;
      });
      return;
    }
    Navigator.of(context).pop('通道接上了，博士');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('接口反代'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '默认地址已经能用；想换成自己的就填在这里，例如 https://bili.example.com。'
              '它负责补上浏览器发不出的 Cookie 和 Referer。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '反代地址',
                hintText: 'https://bili.example.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _test(),
            ),
            if (_hint != null) ...[
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOut,
                child: Row(
                  key: ValueKey('$_hintOk-$_hint'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_hintOk)
                      ScaleTransition(
                        scale: _okScale,
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    else
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _hint!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _hintOk
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : _test,
          child: const Text('测试'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '处理中…' : '保存'),
        ),
      ],
    );
  }
}
