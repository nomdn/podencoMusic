import 'package:material_ui/material_ui.dart';

import 'cover_provider.dart';

/// 网络封面，统一处理「加载中」和「加载失败」两种状态，
/// 否则列表滚动时会看到一片空白格子。
///
/// 缓存策略按平台分流（见 cover_provider.dart 门面）：
///   桌面 → StaticCache 磁盘缓存 + FileImage
///   Web  → NetworkImage（浏览器 HTTP 缓存接管）
/// 两边都以「url → 已解析 provider」的记忆表做去重：列表滚动时 widget
/// 频繁重建，不能每次都重新发起磁盘/网络检查；**null = 确定拿不到**
/// （无网 / URL 失效），同样记入表内，网格里几百张失效封面才不会
/// 每帧重试。
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.url, this.fit = BoxFit.cover});

  final String url;
  final BoxFit fit;

  static final Map<String, ImageProvider?> _resolved = {};
  static final Map<String, Future<ImageProvider?>> _inFlight = {};

  Future<ImageProvider?> _providerFor(String url) {
    if (_resolved.containsKey(url)) {
      return Future.value(_resolved[url]);
    }
    return _inFlight.putIfAbsent(url, () => coverProvider(url));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (url.isEmpty) return _placeholder(scheme);

    return FutureBuilder<ImageProvider?>(
      future: _providerFor(url),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            color: scheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final provider = snapshot.data;
        if (provider == null) return _placeholder(scheme);
        return Image(image: provider, fit: fit);
      },
    );
  }

  Widget _placeholder(ColorScheme scheme) => Container(
    color: scheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
  );
}
