import 'package:material_ui/material_ui.dart';

import 'dart:async';

import '../music_store.dart';
import '../siren_api.dart';
import '../storage.dart';
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

  @override
  void initState() {
    super.initState();
    if (_vivoSupported) unawaited(_loadVivoWhitelist());
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
        const SnackBar(content: Text('地址需要以 http:// 或 https:// 开头')),
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
          content: Text('Shizuku 授权被拒，改走「修改系统设置」方式'),
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
          if (_vivoSupported) ...[
            const SizedBox(height: 24),
            Text('vivo 原子随身听', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'vivo / iQOO 挖孔播放胶囊的白名单开关。OriginOS 4 上加入后'
              '播放时挖孔旁会出现胶囊；OriginOS 5 起系统在代码层另有厂商'
              '白名单（酷狗 / QQ音乐 / 网易云等），写入后不保证生效，'
              '通知栏媒体通知不受影响。有 Shizuku 时自动走 Shizuku（推荐），'
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
