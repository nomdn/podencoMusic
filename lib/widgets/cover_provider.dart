/// 封面 Provider 的条件导出门面。
library;

///
/// 桌面（dart:io 可用）→ 磁盘缓存实现（static_cache + FileImage）；
/// Web（dart.library.html）→ NetworkImage，浏览器 HTTP 缓存接管重复加载。
/// 两个实现导出同签名的顶层 `coverProvider(String url) → Future<ImageProvider?>`，
/// 未命中/失败返回 null（调用方展示占位图）。
export 'cover_provider_io.dart'
    if (dart.library.html) 'cover_provider_web.dart';
