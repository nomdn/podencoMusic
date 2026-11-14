import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../siren_api.dart';
import '../static_cache.dart';

/// 网络封面，带磁盘缓存。封面是静态资源 —— 同一张图只在第一次显示
/// 时走网络，之后读本地文件（FileImage 只持路径，不占内存）。
///
/// 统一处理「加载中」和「加载失败」两种状态，否则列表滚动时会看到
/// 一片空白格子。三个静态表独立于 widget 生命周期：列表滚动时 widget
/// 频繁重建，不能每次都重新发起磁盘/网络检查。
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.url, this.fit = BoxFit.cover});

  final String url;
  final BoxFit fit;

  /// 已解析完的封面：url → FileImage；**null = 确定拿不到**（无网 /
  /// URL 失效），记住它，网格里几百张失效封面才不会每帧重试。
  static final Map<String, ImageProvider?> _resolved = {};

  /// 在途请求：同一张封面并发显示时只发一次磁盘检查/下载。
  static final Map<String, Future<ImageProvider?>> _inFlight = {};

  Future<ImageProvider?> _providerFor(String url) {
    if (_resolved.containsKey(url)) {
      return Future.value(_resolved[url]);
    }
    return _inFlight.putIfAbsent(url, () => _resolve(url));
  }

  Future<ImageProvider?> _resolve(String url) async {
    // 1) 磁盘缓存命中 → 直接读文件
    final cached = await StaticCache.fileFor('cover:$url');
    if (cached != null) return FileImage(cached);

    // 2) 网络下载 → 落盘 → 用落盘文件构造 provider
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw SirenException('HTTP ${res.statusCode}');
      }
      final file = await StaticCache.saveBytes('cover:$url', res.bodyBytes);
      return FileImage(file);
    } catch (_) {
      // 拿不到（无网 / URL 失效）就记住失败，不再对同一 url 反复重试
      return null;
    }
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
