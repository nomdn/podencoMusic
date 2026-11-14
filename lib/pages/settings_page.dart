import 'package:material_ui/material_ui.dart';

import 'dart:async';

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
      SnackBar(content: Text(host.isEmpty ? '已恢复官方接口' : '已保存，接口走：$host')),
    );
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
            '塞壬 API 域名有 CORS 限制：Web 端需要自建一个与官方接口同路径、'
            '只转发流量的反代服务，把反代地址填在这里。桌面 / 安卓原生请求'
            '没有这个限制，留空即可。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: '接口代理地址（根地址，自动补 /api）',
              hintText: '留空使用官方接口',
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
            _usingCustom ? '当前接口：${SirenApi.host}' : '当前接口：官方',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '封面、音频、歌词在鹰角 OSS 上（响应带 CORS 允许头），'
            '始终直连，不经过这里的代理地址。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayerBar(),
    );
  }
}
