/// Web 文件下载的统一入口，按编译目标选择实现。
///
/// dart:js_interop 只存在于 Web 编译目标 —— downloader 直接 import 实现文件
/// 会让原生构建直接炸，所以走条件导入：Web 拿真实现，其它平台拿空壳。
/// 空/真两份实现的 API 必须完全一致（见 web_download_stub.dart 的签名）。
library;

export 'web_download_stub.dart' if (dart.library.js_interop) 'web_download_impl.dart';
