// 托盘用的 windowManager pin 在 0.5.1：0.7 重写的「关窗拦截」实测
// 不生效（WM_CLOSE 直接退出），0.5.1 是经大量桌面应用验证的稳定版。
// 等新版拦截修好再升级。
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:system_tray/system_tray.dart';
// 0.7 把经典的 windowManager 全局 API 挪进了 legacy 导出，托盘场景够用
import 'package:window_manager/window_manager.dart';


import 'downloader.dart';
import 'library.dart';
import 'models.dart';
import 'history_model.dart';
import 'media_handler.dart';
import 'pages/home_page.dart';
import 'player_model.dart';
import 'playlist_model.dart';
import 'siren_api.dart';
import 'storage.dart';
import 'music_store.dart';
/// 托盘与窗口管理相关的桌面开关。window_manager / system_tray 都没有
/// 移动端实现，Android/iOS/Web 上整套逻辑必须跳过。
/// kIsWeb 短路在前面：Web 上 dart:io 的 Platform 桩一碰就抛。
final bool _isDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);


Future<void> main() async {
  // 恢复播放状态要用 shared_preferences，那是平台通道，得先初始化绑定
  WidgetsFlutterBinding.ensureInitialized();

  // 先把上次的队列/模式/音量读回来，再起界面 —— 这样首帧迷你条就是对的
  await playerModel.restore();

  // 歌单和播放历史一起读。都是本地数据，先读再起界面，进页面不用等闪一下
  await playlistsModel.load();
  await historyModel.load();

  // 接口代理地址（设置页可改）：在首次网络请求之前生效
  SirenApi.host = await ApiConfigStorage.load();

  // 扫一遍下载目录，把已经下过的歌记下来。这个可以慢慢来，不阻塞启动。
  unawaited(downloader.scanExisting());

  // Android：把播放桥接成标准媒体通知（MediaSession）。国内各 ROM 的
  // 「灵动岛」类胶囊（小米焦点通知、荣耀灵动胶囊、OPPO 流体云）、锁屏
  // 与耳机线控读的都是这套通知；前台服务同时保住后台播放不被系统杀掉。
  // audio_service 不支持 Windows/Linux 桌面，只在 Android 初始化。
  if (!kIsWeb && Platform.isAndroid) {
    await AudioService.init(
      builder: () => PodencoMediaHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.mint.podencomusic.playback',
        androidNotificationChannelName: '正在播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    // Android 13+ 通知要运行时授权：启动时尽力申请一次，被拒不阻塞
    unawaited(MusicStore.ensureNotificationPermission());
  }

  _registerDebugExtensions();
  if (!kIsWeb) _registerDebugFileHooks();

  // 托盘/关窗隐藏是桌面功能：window_manager 没有移动端实现，
  // 在 Android/iOS 上调用会抛 MissingPluginException。移动端
  // 也没有「窗口」概念，整套托盘逻辑只在桌面三平台启用。
  if (_isDesktop) {
    await windowManager.ensureInitialized();
    windowManager.addListener(_windowCloseHandler);
    await windowManager.setPreventClose(true);
  }

  runApp(const PodencoApp());
  if (_isDesktop) {
    unawaited(_initTray());
  }
}

/// 托盘图标。音乐播放器的托盘价值就一条：窗口关了音乐还在放 ——
/// 点 X 隐藏到托盘，播放控制都在右键菜单里。
final SystemTray _systemTray = SystemTray();
final _WindowCloseHandler _windowCloseHandler = _WindowCloseHandler();

/// 点 X 时拦截（setPreventClose），把窗口藏起来而不是退出。
class _WindowCloseHandler with WindowListener {
  @override
  void onWindowClose() {
    unawaited(windowManager.hide());
  }
}

Future<void> _initTray() async {
  try {
    await _systemTray.initSystemTray(
      iconPath: 'assets/app_icon.ico',
      title: 'Podenco Music',
    );

    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: '显示主窗口',
        onClicked: (_) => unawaited(_showWindow()),
      ),
      MenuItemLabel(
        label: '隐藏主窗口',
        onClicked: (_) => unawaited(windowManager.hide()),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '播放 / 暂停',
        onClicked: (_) => unawaited(playerModel.toggle()),
      ),
      MenuItemLabel(
        label: '上一首',
        onClicked: (_) => unawaited(playerModel.previous()),
      ),
      MenuItemLabel(
        label: '下一首',
        onClicked: (_) => unawaited(playerModel.next()),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出',
        onClicked: (_) => unawaited(_exitFromTray()),
      ),
    ]);
    await _systemTray.setContextMenu(menu);

    // 左键 = 窗口在就藏、藏着就弹；右键 = 弹控制菜单。
    // 事件名常量见 system_tray 的 constants.dart（click / right-click）。
    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        unawaited(_toggleWindow());
      } else if (eventName == kSystemTrayEventRightClick) {
        unawaited(_systemTray.popUpContextMenu());
      }
    });

    // 菜单顶部和悬停提示要跟着「正在播什么 / 在哪个歌单」走。
    // 三路通知都汇到同一个签名守卫：内容没变就不重建。
    playerModel.addListener(_refreshTrayInfo);
    playlistsModel.addListener(_refreshTrayInfo);
    library.addListener(_refreshTrayInfo);
    _refreshTrayInfo();
  } catch (e) {
    // 托盘初始化失败不该拖垮播放器本体
    debugPrint('[tray] 初始化失败：$e');
  }
}

/// 上次托盘菜单对应的播放状态签名，变了才重建菜单。
String _lastTraySignature = '';

/// 重建进行中的标记 + 排队标记：重建是异步的，期间状态又变了就补一次。
bool _trayRebuilding = false;
bool _trayRebuildQueued = false;

/// 当前这首歌所在的歌单名（可能在多个里）。
List<String> _playlistsContaining(Track? track) {
  if (track == null) return const [];
  return playlistsModel.playlists
      .where((p) => p.tracks.any((t) => t.cid == track.cid))
      .map((p) => p.name)
      .toList();
}

/// 曲目 / 播放状态 / 专辑名 / 歌单归属 / 歌单结构 / 专辑缓存
/// 任一变化时重建托盘菜单并更新悬停提示。
/// 播放进度那种 5Hz 通知在这里只做一次字符串比较。
Future<void> _refreshTrayInfo() async {
  final track = playerModel.current;
  final inLists = _playlistsContaining(track);
  // 歌单结构和专辑缓存数量参与签名：增删歌单 / 访问新专辑都要重建
  final playlistsSig = playlistsModel.playlists
      .map((p) => '${p.name}:${p.tracks.length}')
      .join(',');
  final signature =
      '${track?.cid}|${playerModel.playing}|'
      '${library.albumNameOf(track?.albumCid ?? "")}|${inLists.join(",")}|'
      '$playlistsSig|${SirenApi.sessionAlbumDetails.length}';
  if (signature == _lastTraySignature) return;
  _lastTraySignature = signature;

  if (_trayRebuilding) {
    _trayRebuildQueued = true;
    return;
  }
  _trayRebuilding = true;
  try {
    await _rebuildTrayMenu(inLists);
  } finally {
    _trayRebuilding = false;
    if (_trayRebuildQueued) {
      _trayRebuildQueued = false;
      unawaited(_refreshTrayInfo());
    }
  }
}

Future<void> _rebuildTrayMenu(List<String> inLists) async {
  final track = playerModel.current;
  final items = <MenuItemBase>[];

  if (track != null) {
    final album = library.albumNameOf(track.albumCid);
    final artist = track.artists.isEmpty ? '' : track.artists.first;
    // 悬停提示：歌名 - 艺人 + 专辑 + 歌单归属
    final tooltipLines = [
      '正在播放：${track.name}${artist.isEmpty ? '' : ' - $artist'}',
      if (album.isNotEmpty) '专辑：$album',
      if (inLists.isNotEmpty) '歌单：${inLists.join('、')}',
    ];
    await _systemTray.setToolTip(tooltipLines.join('\n'));

    // 菜单顶部的灰色信息行（enabled: false = 只展示不可点）
    items.add(MenuItemLabel(label: track.name, enabled: false));
    if (album.isNotEmpty) {
      items.add(MenuItemLabel(label: '专辑：$album', enabled: false));
    }
    items.add(
      MenuItemLabel(
        label: inLists.isEmpty ? '不在任何歌单' : '歌单：${inLists.join('、')}',
        enabled: false,
      ),
    );
    items.add(MenuSeparator());
  }

  // 播放控制
  items.addAll([
    MenuItemLabel(
      label: playerModel.playing ? '暂停' : '播放',
      onClicked: (_) => unawaited(playerModel.toggle()),
    ),
    MenuItemLabel(
      label: '上一首',
      onClicked: (_) => unawaited(playerModel.previous()),
    ),
    MenuItemLabel(
      label: '下一首',
      onClicked: (_) => unawaited(playerModel.next()),
    ),
    MenuSeparator(),
  ]);

  // 歌单子菜单：每个歌单 → 每首曲目（点了就从那首开始放整个歌单）
  final playlists = playlistsModel.playlists;
  final playlistSubitems = <MenuItemBase>[];
  for (final playlist in playlists) {
    if (playlist.tracks.isEmpty) continue;
    final tracks = playlist.tracks;
    playlistSubitems.add(
      SubMenu(
        label: '${playlist.name}（${tracks.length}）',
        children: [
          for (final (i, t) in tracks.indexed)
            MenuItemLabel(
              label: '${i + 1}. ${t.name}',
              onClicked: (_) =>
                  unawaited(playerModel.playQueue(tracks, start: i)),
            ),
        ],
      ),
    );
  }
  if (playlistSubitems.isNotEmpty) {
    items.add(SubMenu(label: '歌单', children: playlistSubitems));
  }

  // 专辑子菜单：数据来自会话内存缓存（本次运行打开过的专辑）。
  // 当前播放的专辑不在会话缓存里就拉一次，拉完 _refreshTrayInfo
  // 会被播放器的周期通知再次触发，菜单自己补上。
  if (track != null &&
      !SirenApi.sessionAlbumDetails.any((d) => d.cid == track.albumCid)) {
    unawaited(
      SirenApi.albumDetail(track.albumCid).then((_) => _refreshTrayInfo()),
    );
  }
  final albumDetails = SirenApi.sessionAlbumDetails;
  albumDetails.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );
  if (albumDetails.isNotEmpty) {
    items.add(
      SubMenu(
        label: '专辑',
        children: [
          for (final detail in albumDetails)
            SubMenu(
              label: '${detail.name}（${detail.songs.length}）',
              children: [
                for (final (i, t) in detail.songs.indexed)
                  MenuItemLabel(
                    label: '${i + 1}. ${t.name}',
                    onClicked: (_) => unawaited(
                      playerModel.playQueue(detail.songs, start: i),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // 窗口与退出
  items.addAll([
    MenuSeparator(),
    MenuItemLabel(
      label: '显示主窗口',
      onClicked: (_) => unawaited(_showWindow()),
    ),
    MenuItemLabel(
      label: '隐藏主窗口',
      onClicked: (_) => unawaited(windowManager.hide()),
    ),
    MenuSeparator(),
    MenuItemLabel(
      label: '退出',
      onClicked: (_) => unawaited(_exitFromTray()),
    ),
  ]);

  final menu = Menu();
  await menu.buildFrom(items);
  await _systemTray.setContextMenu(menu);
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

Future<void> _toggleWindow() async {
  if (await windowManager.isVisible()) {
    await windowManager.hide();
  } else {
    await _showWindow();
  }
}

/// 托盘菜单的「退出」。preventClose 拦得住 WM_CLOSE，拦不住 destroy。
Future<void> _exitFromTray() async {
  try {
    await _systemTray.destroy();
  } catch (_) {}
  await windowManager.destroy();
}

/// 仅 debug：调试服务扩展。release 包 kDebugMode 为 false，
/// 注册根本不会发生，不影响发布产物。
void _registerDebugExtensions() {
  if (!kDebugMode) return;

  developer.registerExtension('ext.podenco/state', (method, params) async {
    final state = {
      'loading': playerModel.loading,
      'playing': playerModel.playing,
      'posMs': playerModel.position.inMilliseconds,
      'durMs': playerModel.duration.inMilliseconds,
      'error': playerModel.error,
      'hasDetail': playerModel.detail != null,
      'cid': playerModel.current?.cid,
      'historyLen': historyModel.tracks.length,
      'queued': downloader.pendingTracks.length,
    };
    return developer.ServiceExtensionResponse.result(jsonEncode(state));
  });

  developer.registerExtension('ext.podenco/toggle', (method, params) async {
    unawaited(playerModel.toggle());
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'triggered': true}),
    );
  });
}

/// 状态落盘诊断钩子，release 也开着（暂不回收）。
///
/// 这台机器的播放问题只在其真实运行环境里复现得出来，显示又是虚拟
/// 适配器 + 串流，肉眼验证不可靠 —— 所以把播放器状态每秒写到临时目录，
/// 自动化验证直接读文件拿时间线。等播放问题彻底稳定后移除。
void _registerDebugFileHooks() {
  final temp = Directory.systemTemp.path;
  final stateFile = File('$temp${Platform.pathSeparator}podenco_state.log');
  final triggerFile = File('$temp${Platform.pathSeparator}podenco_play.trigger');

  // 上次运行的旧日志清掉
  try {
    if (stateFile.existsSync()) stateFile.deleteSync();
  } catch (_) {}

  Timer.periodic(const Duration(seconds: 1), (_) {
    try {
      final line = jsonEncode({
        't': DateTime.now().toIso8601String(),
        'loading': playerModel.loading,
        'playing': playerModel.playing,
        'posMs': playerModel.position.inMilliseconds,
        'durMs': playerModel.duration.inMilliseconds,
        'error': playerModel.error,
        'hasDetail': playerModel.detail != null,
        'cid': playerModel.current?.cid,
        'queued': downloader.pendingTracks.length,
        'historyLen': historyModel.tracks.length,
      });
      stateFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  });

  Timer.periodic(const Duration(milliseconds: 500), (_) async {
    try {
      if (await triggerFile.exists()) {
        final what = await triggerFile.readAsString();
        await triggerFile.delete();
        // 文件内容：空/'toggle' = 点播放；'seekEnd' = 拨到歌曲末尾；
        // 'queueAll' = 对当前这首歌所在的专辑跑一遍批量入队，
        // 结果写回状态文件（诊断批量下载管线用）
        if (what.trim() == 'seekEnd' && playerModel.hasTrack) {
          final dur = playerModel.duration;
          final target = dur > const Duration(seconds: 4)
              ? dur - const Duration(seconds: 2)
              : Duration.zero;
          unawaited(playerModel.seek(target));
        } else if (what.trim() == 'queueAll' && playerModel.hasTrack) {
          final albumCid = playerModel.current!.albumCid;
          try {
            final detail = await SirenApi.albumDetail(albumCid);
            final result = await downloader.queueAll(detail.songs);
            stateFile.writeAsStringSync(
              'queueAll: added=${result.added} skipped=${result.skipped} '
              'blocked=${result.blockedReason ?? "-"}\n',
              mode: FileMode.append,
              flush: true,
            );
          } catch (e) {
            stateFile.writeAsStringSync(
              'queueAll: threw $e\n',
              mode: FileMode.append,
              flush: true,
            );
          }
        } else {
          unawaited(playerModel.toggle());
        }
      }
    } catch (_) {}
  });
}

/// 应用外壳。只干两件事：定主题、指定首页。
///
/// 主题特意保持 Material 3 默认外观 —— 不改圆角、不改字体、不叠渐变。
/// 只给了颗琥珀色种子（跟塞壬的黄色调对得上），其余配色由 M3 自己推导。
class PodencoApp extends StatelessWidget {
  const PodencoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Podenco Music',
      debugShowCheckedModeBanner: false,
      theme: _build(Brightness.light),
      darkTheme: _build(Brightness.dark),
      // 跟随系统。桌面上想在标题栏里切换的话，把这里改成固定值即可。
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }

  ThemeData _build(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFE8B33C),
        brightness: brightness,
      ),
    );
  }
}
