/// 非 Web 平台的空实现 —— 条件导入的兜底（见 web_download.dart）。
///
/// 所有方法只在 Web 编译目标里被调用（调用方先判 webFsSupported），
/// 这里给出的行为只是「保持类型完整」的安全兜底。
library;

/// 一次 Web 下载的取消句柄。空实现里什么都不做。
class WebDownloadHandle {
  const WebDownloadHandle();

  void abort() {}
}

/// File System Access API 是否可用。非 Web 平台恒为 false。
const bool webFsSupported = false;

/// 非 Web 平台的空实现。
class WebFsAccess {
  const WebFsAccess();

  /// 弹目录选择框 / 续权。非 Web 恒 false（按钮根本不会显示）。
  Future<bool> ensureDirectoryAccess() async => false;

  /// 启动时恢复句柄并只查询权限（不弹任何框）。空实现。
  Future<void> querySavedAccess() async {}

  /// 强制重选下载目录。非 Web 恒 false。
  Future<bool> pickDirectory() async => false;

  /// 列出授权目录里已有的文件名。空实现。
  Future<List<String>> listSavedDirectory() async => const [];

  /// 创建一次下载的取消句柄。
  WebDownloadHandle createDownloadHandle() => const WebDownloadHandle();

  /// 流式下载到授权目录。空实现里永远不会被调用。
  Future<String> writeFileFromUrl({
    required String url,
    required String fileName,
    required void Function(double progress) onProgress,
    required WebDownloadHandle handle,
  }) async {
    throw UnsupportedError('仅 Web 支持');
  }
}

/// 全局单例。
const WebFsAccess webFs = WebFsAccess();
