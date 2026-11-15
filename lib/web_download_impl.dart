/// Web 端文件下载实现：File System Access API（Chromium 系专属）。
///
/// 用户授权一个目录（showDirectoryPicker），句柄存 IndexedDB 跨会话复用；
/// 下载用 fetch 流式读、FileSystemWritableFileStream 流式写 ——
/// 不把整首歌读进内存，几十 MB 的 wav 也稳。
///
/// 浏览器可能把目录权限定期收回（queryPermission 从 granted 变 prompt），
/// 所以每次会话要重新 query，prompt 态在下一次点击的用户手势里静默续权。
///
/// 句柄（FileSystemDirectoryHandle）可结构化克隆、能进 IndexedDB，
/// 这是「授权一次、跨会话复用」的关键 —— localStorage 存不了句柄。
///
/// 本文件只经 web_download.dart 的条件导入被 Web 编译目标引用；
/// 原生目标拿到的是 web_download_stub.dart，dart:js_interop 在那边不存在。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// 一次 Web 下载的取消句柄，包着 AbortController。
class WebDownloadHandle {
  WebDownloadHandle() : _controller = _newAbortController();

  final JSObject _controller;

  void abort() {
    try {
      _controller.callMethod('abort'.toJS);
    } catch (_) {}
  }
}

/// File System Access API 是否可用（Chromium 系浏览器）。
final bool webFsSupported =
    globalContext.hasProperty('showDirectoryPicker'.toJS).toDart;

class WebFsAccess {
  JSObject? _dir;
  bool _granted = false;

  static const _dbName = 'podenco-fs';
  static const _storeName = 'handles';

  /// 弹目录选择框 / 恢复句柄并续权。必须在用户手势（按钮回调）里调用。
  Future<bool> ensureDirectoryAccess() async {
    if (!webFsSupported) return false;
    if (_dir != null && _granted) return true;

    final saved = await _loadSavedDir();
    if (saved != null) {
      _dir = saved;
      // query 已 granted 就直接用；prompt 态借着手势静默续权
      if (await _queryOrRequest(saved, request: false)) {
        _granted = true;
        return true;
      }
      if (await _queryOrRequest(saved, request: true)) {
        _granted = true;
        return true;
      }
      _dir = null;
      return false;
    }
    return pickDirectory();
  }

  /// 启动时恢复句柄并只查询权限（非手势上下文，绝不弹任何框）。
  Future<void> querySavedAccess() async {
    if (!webFsSupported) return;
    final saved = await _loadSavedDir();
    if (saved == null) return;
    _dir = saved;
    _granted = await _queryOrRequest(saved, request: false);
  }

  /// 强制重选下载目录（换地方下载用）。
  Future<bool> pickDirectory() async {
    if (!webFsSupported) return false;
    _granted = false;
    _dir = null;
    try {
      final options = JSObject()
        ..setProperty('mode'.toJS, 'readwrite'.toJS)
        // id 让浏览器记住上次的选择位置；startIn 落到系统音乐目录
        ..setProperty('id'.toJS, 'podenco-downloads'.toJS)
        ..setProperty('startIn'.toJS, 'music'.toJS);
      final dir = await (globalContext
              .callMethod('showDirectoryPicker'.toJS, options) as JSPromise)
          .toDart as JSObject?;
      if (dir == null) return false;
      _dir = dir;
      _granted = true; // 带 mode:readwrite 的选择框，选中即授权
      unawaited(_saveDir(dir));
      return true;
    } catch (_) {
      // 用户点了取消（AbortError）等
      return false;
    }
  }

  /// 列出授权目录里已有的文件名。没授权 / 权限中途被收回就当空目录。
  Future<List<String>> listSavedDirectory() async {
    final dir = _dir;
    if (dir == null || !_granted) return const [];
    final names = <String>[];
    try {
      final iterator = dir.callMethod('values'.toJS) as JSObject;
      while (true) {
        final next = await (iterator.callMethod('next'.toJS) as JSPromise)
            .toDart as JSObject;
        if ((next.getProperty('done'.toJS) as JSBoolean).toDart) break;
        final value = next.getProperty('value'.toJS) as JSObject;
        final name = value.getProperty('name'.toJS);
        if (name.isA<JSString>()) names.add((name as JSString).toDart);
      }
    } catch (_) {}
    return names;
  }

  WebDownloadHandle createDownloadHandle() => WebDownloadHandle();

  /// 流式下载到授权目录。返回写入的文件名；失败 / 取消抛异常（调用方
  /// 统一收尾），写一半的残缺文件会被删掉。
  Future<String> writeFileFromUrl({
    required String url,
    required String fileName,
    required void Function(double progress) onProgress,
    required WebDownloadHandle handle,
  }) async {
    final dir = _dir;
    if (dir == null || !_granted) {
      throw Exception('尚未授权下载目录');
    }

    final init = JSObject()
      ..setProperty('method'.toJS, 'GET'.toJS)
      ..setProperty('signal'.toJS, handle._controller.getProperty('signal'.toJS));
    late final JSObject response;
    try {
      response = await (globalContext
              .callMethod('fetch'.toJS, url.toJS, init) as JSPromise)
          .toDart as JSObject;
    } catch (e) {
      throw Exception('[fetch] $e');
    }
    final status = (response.getProperty('status'.toJS).dartify() as num).toInt();
    if (status != 200) {
      throw Exception('下载失败：HTTP $status');
    }

    // Content-Length 拿不到就报不确定进度（与原生行为一致）
    var total = 0;
    late final JSObject responseHeaders;
    try {
      responseHeaders = response.getProperty('headers'.toJS) as JSObject;
    } catch (e) {
      throw Exception('[headers] $e');
    }
    final lengthHeader =
        responseHeaders.callMethod('get'.toJS, 'content-length'.toJS);
    if (lengthHeader.isDefinedAndNotNull) {
      total = int.tryParse((lengthHeader as JSString).toDart) ?? 0;
    }

    late final JSObject fileHandle;
    try {
      // getFileHandle 返回 Promise，必须 await —— 漏了 await 就会拿着
      // Promise 对象去调 createWritable，报 a[b] is not a function
      fileHandle = await (dir.callMethod(
        'getFileHandle'.toJS,
        fileName.toJS,
        JSObject()..setProperty('create'.toJS, true.toJS),
      ) as JSPromise)
          .toDart as JSObject;
    } catch (e) {
      throw Exception('[getFileHandle] $e');
    }

    // 已存在且不是空壳，直接当成成功（与桌面端 _saveToFolder 同语义）。
    // 这条也顺带消化掉历史遗留的 0 字节残骸 —— 它们会被重新下载覆盖。
    try {
      final existing = await (fileHandle.callMethod('getFile'.toJS) as JSPromise)
          .toDart as JSObject;
      final size = (existing.getProperty('size'.toJS).dartify() as num).toInt();
      if (size > 64 * 1024) return fileName;
    } catch (_) {
      // 读不到大小就照常下载
    }

    late final JSObject writable;
    try {
      // 同上：createWritable 也是 Promise
      writable = await (fileHandle.callMethod('createWritable'.toJS) as JSPromise)
          .toDart as JSObject;
    } catch (e) {
      // 文件条目已经建出来了，留着会变成 0 字节僵尸（还会被扫成「已下载」）
      await _removeEntry(dir, fileName);
      throw Exception('[createWritable] $e');
    }

    try {
      late final JSObject reader;
      try {
        reader =
            (response.getProperty('body'.toJS) as JSObject)
                .callMethod('getReader'.toJS) as JSObject;
      } catch (e) {
        throw Exception('[getReader] $e');
      }
      var received = 0;
      while (true) {
        late final JSObject chunk;
        try {
          chunk = await (reader.callMethod('read'.toJS) as JSPromise).toDart
              as JSObject;
        } catch (e) {
          throw Exception('[read] $e');
        }
        if ((chunk.getProperty('done'.toJS) as JSBoolean).toDart) break;
        final value = chunk.getProperty('value'.toJS);
        if (value.isUndefinedOrNull) continue;
        final bytes = (value as JSUint8Array).toDart;
        try {
          await (writable.callMethod('write'.toJS, bytes.toJS) as JSPromise)
              .toDart;
        } catch (e) {
          throw Exception('[write] $e');
        }
        received += bytes.length;
        if (total > 0) onProgress(received / total);
      }
      try {
        await (writable.callMethod('close'.toJS) as JSPromise).toDart;
      } catch (e) {
        throw Exception('[close] $e');
      }
      return fileName;
    } catch (_) {
      // 写一半失败 / 被取消：删掉半截文件，别留下看着正常的残缺品
      await _removeEntry(dir, fileName);
      rethrow;
    }
  }

  /// 删掉目录里的某个文件条目。失败静默 —— 清理是尽力而为。
  Future<void> _removeEntry(JSObject dir, String fileName) async {
    try {
      await (dir.callMethod('removeEntry'.toJS, fileName.toJS) as JSPromise)
          .toDart;
    } catch (_) {}
  }

  // ── 浏览器 API 原始交互 ─────────────────────────────────

  Future<bool> _queryOrRequest(JSObject handle, {required bool request}) async {
    try {
      final options = JSObject()..setProperty('mode'.toJS, 'readwrite'.toJS);
      final promise = handle.callMethod(
        (request ? 'requestPermission' : 'queryPermission').toJS,
        options,
      ) as JSPromise;
      final state = (await promise.toDart) as JSString;
      return state.toDart == 'granted';
    } catch (_) {
      return false;
    }
  }

  Future<JSObject?> _loadSavedDir() async {
    try {
      final db = await _openDb();
      final tx =
          db.callMethod('transaction'.toJS, _storeName.toJS) as JSObject;
      final store =
          tx.callMethod('objectStore'.toJS, _storeName.toJS) as JSObject;
      final result =
          await _waitFor(store.callMethod('get'.toJS, 'dir'.toJS) as JSObject);
      return result.isDefinedAndNotNull ? result as JSObject : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDir(JSObject handle) async {
    try {
      final db = await _openDb();
      final tx = db.callMethod(
        'transaction'.toJS,
        _storeName.toJS,
        'readwrite'.toJS,
      ) as JSObject;
      final store =
          tx.callMethod('objectStore'.toJS, _storeName.toJS) as JSObject;
      store.callMethod('put'.toJS, handle, 'dir'.toJS);
    } catch (_) {
      // 存不下就不跨会话复用，退化为每次会话重选一次目录
    }
  }

  Future<JSObject> _openDb() {
    final completer = Completer<JSObject>();
    final idb = globalContext.getProperty('indexedDB'.toJS) as JSObject;
    final request =
        idb.callMethod('open'.toJS, _dbName.toJS, 1.toJS) as JSObject;
    request.setProperty('onupgradeneeded'.toJS, ((JSAny? _) {
      (request.getProperty('result'.toJS) as JSObject)
          .callMethod('createObjectStore'.toJS, _storeName.toJS);
    }).toJS);
    request.setProperty('onsuccess'.toJS, ((JSAny? _) {
      completer.complete(request.getProperty('result'.toJS) as JSObject);
    }).toJS);
    request.setProperty('onerror'.toJS, ((JSAny? _) {
      completer.completeError(Exception('IndexedDB 打开失败'));
    }).toJS);
    return completer.future;
  }

  /// 把 IDBRequest 包成 Future：成功取 result，失败 completeError。
  Future<JSAny?> _waitFor(JSObject request) {
    final completer = Completer<JSAny?>();
    request.setProperty('onsuccess'.toJS, ((JSAny? _) {
      completer.complete(request.getProperty('result'.toJS));
    }).toJS);
    request.setProperty('onerror'.toJS, ((JSAny? _) {
      completer.completeError(Exception('IndexedDB 请求失败'));
    }).toJS);
    return completer.future;
  }
}

JSObject _newAbortController() {
  final ctor = globalContext.getProperty('AbortController'.toJS) as JSFunction;
  return ctor.callAsConstructor() as JSObject;
}

/// 全局单例。
final WebFsAccess webFs = WebFsAccess();
