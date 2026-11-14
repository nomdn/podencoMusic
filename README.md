# Podenco Music

塞壬唱片（[monster-siren.hypergryph.com](https://monster-siren.hypergryph.com/music)）的非官方客户端，
Flutter 写的，一套代码跑 Windows / Android。

界面全部用 Material 3 默认组件，没有自定义配色和圆角 —— 只给了一颗琥珀色种子色。

## 跑起来

```bash
# 桌面（改代码保存后按 r 热重载最快）
flutter run -d windows

# 安卓模拟器
flutter emulators --launch Pixel_8
flutter run

# 出安装包
flutter build apk --release
```

**日常使用跑 release 包**（`build\windows\x64\runner\Release\podenco_music.exe`），
debug 构建（JIT + 断言）在这台机器上慢一个量级。

**这台机器必须关 Impeller**：机器上装了 GameViewer / MuMu 虚拟显示适配器，
Impeller 会落进 OpenGLES 软件渲染路径（运行日志里的 `OpenGLESSDF`），帧时间
慢到整屏像冻住 —— 按钮不刷新、点击不响应全是它。`windows/runner/main.cpp`
里已经 `set_impeller_switch(ImpellerSwitch::Disabled)` 强制走 Skia，debug 和
release 都生效。换到没有虚拟显示适配器的正常硬件上，删掉那行即可。

**还有一个呈现层的坑（这个是画面冻结的真正元凶）**：应用渲染完全正常、模型
状态全对，但窗口在屏幕上停着几分钟前的旧帧 —— GameViewer / MuMu 的两个虚拟
显示适配器把 ANGLE 的 D3D 设备引到虚拟适配器上，交换链的 Present 静默失败。
确诊方法：PrintWindow 抓窗口内容（强制最新）对比 CopyFromScreen 抓屏幕
（用户所见），两者相差几十秒就是它。解法是禁用虚拟适配器：

```powershell
Get-PnpDevice -Class Display |
  Where-Object { $_.FriendlyName -match 'GameViewer|MuMu' } |
  Disable-PnpDevice -Confirm:$false
# 需要用 GameViewer / MuMu 时再 Enable-PnpDevice 启用回来
```

实测效果：禁用后屏幕画面与模型状态逐秒同步。per-app GPU preference
（`GpuPreference=1`）在这台机器上无效，虚拟适配器照样被选中。

四个依赖：`http`（请求接口）、`audioplayers`（播放音频）、`path_provider`（找下载目录）、
`shared_preferences`（存播放状态）。

## 代码地图

| 文件 | 职责 | 行数 |
| --- | --- | --- |
| `lib/main.dart` | 入口 + 主题 + 启动时恢复状态 | 56 |
| `lib/models.dart` | 五个数据模型 + PlayMode 枚举 | 227 |
| `lib/siren_api.dart` | 网络请求（带超时）+ LRC 解析 | 133 |
| `lib/library.dart` | 全站数据的内存缓存（ChangeNotifier） | 86 |
| `lib/player_model.dart` | 播放器状态：队列、进度、歌词、模式、音量 | 457 |
| `lib/playlist_model.dart` | 歌单状态：建/删/改名、加/移歌（ChangeNotifier） | 126 |
| `lib/history_model.dart` | 播放历史：最近 100 首，新的在前 | 49 |
| `lib/storage.dart` | 播放状态 / 歌单 / 历史 / 排序偏好的本地读写 | 184 |
| `lib/downloader.dart` | 下载：单曲直下 + 批量串行队列 + 已下载记录 | 532 |
| `lib/disk_space.dart` | Windows FFI 查剩余磁盘空间（批量下载前检查） | 69 |
| `lib/music_store.dart` | Android 系统 Music 目录的读写，走原生 MethodChannel | 68 |
| `lib/pages/home_page.dart` | 专辑网格 + 排序菜单 | 262 |
| `lib/pages/album_page.dart` | 专辑详情 + 曲目列表 + 下载全部 | 252 |
| `lib/pages/search_page.dart` | 搜索（本地过滤） | 221 |
| `lib/pages/playlists_page.dart` | 歌单列表（新建 / 重命名 / 删除） | 185 |
| `lib/pages/playlist_detail_page.dart` | 歌单详情 + 曲目列表 | 223 |
| `lib/pages/history_page.dart` | 播放历史 | 116 |
| `lib/pages/downloads_page.dart` | 下载管理：进行中 / 队列 / 已完成 / 失败 | 306 |
| `lib/pages/player_page.dart` | 播放页（宽屏分栏 / 窄屏堆叠） | 449 |
| `lib/widgets/` | 封面、迷你播放条、音量、下载、错误态、加歌弹层、歌单对话框 | 633 |

建议阅读顺序：`models` → `siren_api` → `library` → `player_model` → `storage` → 随便挑一个 page。

## 一次点击发生了什么

以「首页点一张专辑 → 点第 3 首」为例：

1. `_AlbumCard.onTap` → `Navigator.push(AlbumPage(album))`
2. `AlbumPage.initState` → `SirenApi.albumDetail(cid)` 拿到曲目列表
3. 点第 3 首 → `playerModel.playQueue(songs, start: 2)`
4. `PlayerModel._load()`：
   - `SirenApi.songDetail(cid)` 换到音频直链（列表接口里**没有**播放地址，这步省不掉）
   - `_audio.setSourceUrl(...)` → `resume()`
   - `notifyListeners()` → 迷你播放条和播放页一起重建
   - 歌词同时在后台拉，回来再 `notifyListeners()`
5. `onPositionChanged` 每 200ms 触发一次 → 重算歌词高亮行 → 播放页把那一行滚到中间

## 几个绕不开的坑（代码里都注释了）

**列表接口不给播放地址。** `/api/songs` 只有 cid 和歌名，要播必须再调 `/api/song/{cid}`。
所以点击到出声之间必然有一段等待，没法预加载。

**音频直链带签名，会过期。** URL 长这样：
`https://res01.hycdn.cn/<token>/<token>/siren/audio/20220608/xxx.mp3`
中间两段是防盗链签名。这意味着**不能把 URL 存下来下次用**，每次播放都得重新换。

**格式不统一。** 老歌是 `.mp3`（几 MB），2023 年之后大量是 `.wav`（几十 MB）。
同一个专辑里两种混着。所以下载只做了单曲，没做「整张一键下载」——
一张 wav 专辑轻松 500MB 往上，得先做下载队列和磁盘空间检查。

**接口没有 CORS 头。** 所以 Web 版跑不起来（浏览器会拦 `monster-siren` 的请求），
桌面端和安卓不受影响（Dart 的 HttpClient 不管 CORS）。
图片 CDN 倒是给了 `Access-Control-Allow-Origin: *`，所以 Web 上图片能显示、数据拿不到。

**搜索是本地过滤。** 塞壬没有搜索接口，但全站只有 900 多首歌，
一次拉完在内存里过滤比发请求快得多。

**Track 不带封面。** 接口只给 `albumCid`，要显示封面得按 albumCid 反查专辑。
这就是 `library.dart` 存在的原因 —— 与其每个页面各拉一遍专辑列表，不如存一份。

## 下载

| 平台 | 存到哪 |
| --- | --- |
| Windows / macOS | 系统下载目录下的 `PodencoMusic/`（Windows 就是 `C:\Users\<你>\Downloads\PodencoMusic`） |
| Android | 系统 Music 目录下的 `PodencoMusic/`（走 MediaStore，`Music/PodencoMusic`），系统音乐 App 直接能扫到 |
| 其它 | 应用文档目录 |

**下载完成后自动写元数据**（ID3v2.3）：歌名 / 艺人 / 专辑 / 曲目号 / 专辑封面
—— 封面优先取本地封面缓存，没有才走网络。MP3 写进文件头；WAV 包进 RIFF
`id3 ` 附加块追加到文件尾（资源管理器不认 WAV 的这个块，foobar2000 / VLC
认 —— WAV 格式本身没有统一解法）。元数据写入失败只丢标签，文件照常保留。
CDN 自带的旧 ID3 标签会被替换而不是叠加。纯 Dart 实现零额外依赖。

文件名是 `艺人 - 歌名.mp3/wav`，非法字符会替换成下划线。

下载分两种：列表页/播放页的按钮是**单曲直下**；专辑页的「下载全部」进**串行队列**，
在下载管理页（首页右上角）看进度、取消、重试。批量入队前会查一次剩余磁盘空间
（Windows 走 FFI 调 `GetDiskFreeSpaceExW`，安卓走 StatFs），低于 1GB 整批拦下
—— 一张 wav 专辑轻松 500MB 往上，下到一半盘满了比提前拦住难堪多了。

实现上有三个细节值得看：

- **先写 `.part` 再改名**。中途断网不会留下一个看着正常其实残缺的文件，失败时也会把半截文件删掉。
- **文件名主干只依赖 Track**（艺人 + 歌名），不含音频地址。所以 `scanExisting()` 启动时扫一遍目录就能判断「哪些歌已经下过」，不用请求网络。
- **队列是串行的**。几十 MB 的 wav 并发只会互相抢带宽，取消正在下的那首靠掐断 `http.Client`，半截文件由各自的失败清理逻辑删掉。

所有平台下载完都能「打开文件夹」：桌面 `explorer.exe` / `open` / `xdg-open`，
安卓走 DocumentsUI 的目录浏览 intent 直接跳到 `Music/PodencoMusic`。

## 持久化

用 `shared_preferences` 存一份 JSON：**队列、播到第几首、播放模式、音量**。

歌单（`playlists_v1`）、播放历史（`history_v1`，上限 100 首）、首页排序偏好
（`albums_sort_by_name`）各有各的 key，同样整存整取 —— 曲目复用 `Track` 的序列化，
只存坐标信息（cid / 歌名 / 专辑 / 艺人），不存播放地址。歌单和历史是低频操作，
不做防抖，改一次写一次；播放器状态保持 600ms 防抖。

**故意不存播放进度**。音频直链带签名会过期，恢复时反正要重新换源，存个 seek 位置也用不上；而且如果恢复后自动接着放，一开 app 就出声，很打扰。所以恢复出来的是暂停态，点播放才真正加载（`toggle()` 里 `_detail == null` 就走完整加载流程）。

写入是 600ms 防抖：连续切歌、拖音量条时不会每次都写盘。

## 播放模式

三种，按钮点一下轮着切：

| 模式 | 图标 | 播完一首 |
| --- | --- | --- |
| 列表循环 | `repeat` | 顺序下一首，到末尾回第一首 |
| 单曲循环 | `repeat_one` | 进度拨回 0 接着放，不重新换源 |
| 随机 | `shuffle` | 随机挑一个和当前不同的 |

「上一首」在随机模式下不走随机 —— 随机的反向没法定义，退回顺序表里的前一首是用户普遍预期。

## 已经做了的

- 专辑网格（响应式 2~6 列）、专辑详情、搜索（专辑 + 歌曲）、播放页、迷你播放条
- 播放队列、上一首/下一首、进度拖动、歌词同步滚动
- **系统托盘**：点 X 隐藏到托盘继续放歌（真退出走托盘菜单「退出」）；左键点图标 = 弹回/隐藏窗口；右键菜单 = 显示/隐藏、播放/暂停、上一首/下一首、退出。托盘依赖 `system_tray` + `window_manager`（pin 0.5.1 —— 0.7 重写的关窗拦截实测失效）
- 三种播放模式（列表循环 / 单曲循环 / 随机）
- 多个自建歌单：首页右上角进，建/删/改名；单曲加歌 = 搜索页和专辑页长按曲目、播放页一键；**整张专辑加入** = 专辑详情页头部「加入歌单」；**歌单批量下载** = 歌单详情页「下载全部」；整单播放
- 静态资源磁盘缓存（`static_cache/`）：**封面图片、歌词**这类内容永不变化的资源，只在第一次走网络，之后读本地文件；专辑详情/列表是动态内容，只做会话内内存去重，不落盘
- 播放历史：最近 100 首，新的在前，点哪首从哪首播
- 专辑排序：默认顺序 / 按名称，偏好记在本地
- 单曲下载 + 整张专辑批量下载（串行队列 + 磁盘空间检查），下载管理页看进度、取消、重试
- 音量：弹出面板带滑块，可静音；换源后会自动重新设一次（`audioplayers` 换源会重置音量）
- 状态持久化：队列 / 下标 / 模式 / 音量（600ms 防抖）、歌单、历史、排序偏好
- 宽窄屏两套布局：≥800 宽左右分栏，窄屏上下堆叠
- LRC 解析、播放器持久化、歌单、历史、下载队列各有单测（`flutter test`，共 29 个用例）

播放状态这块吃过一次亏，现在的规矩是：**UI 任何情况下都不能冻死**。播放器的
「正在播放」以插件的 `onPlayerStateChanged` 为准（手写的状态只做即时反馈），
每个可能挂起的 await 都有超时兜底，Windows 端丢平台回复不再能让按钮和进度条卡死。

## 还没做的

- 播放历史按日期分组 / 收藏标记
- 下载失败自动重试（现在失败要手动点重试）
- Web 版（接口没有 CORS 头，浏览器拦 `monster-siren` 的请求，得自己架一层代理）

