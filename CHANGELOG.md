# Changelog

本文件记录 Podenco Music 各版本的变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。条目按版本倒序排列。

## [Unreleased]

### Removed
- 下载时不再往 MediaStore 的 `TITLE` / `ARTIST` 两列写元数据。这两列会被系统媒体扫描用文件内嵌标签回填覆盖，插入时写的值留不住；决定设备显示什么的自始至终是文件标签本身。

### Fixed
- WAV 的 `LIST/INFO` 与 `id3 ` 标签块改插到 `data` 之前。原先追加在文件尾，只在 `data` 前扫标签的解析器读不到；ffprobe 这类会走完整条块链，容易造成「本地验证通过、设备上读不到」的误判。

## [1.1.8] - 2026-11-21

### Added
- Android 在通用包之外，另发三个分架构安装包：`arm64-v8a`、`armeabi-v7a`、`x86_64`。通用包要装三套原生库，体积接近 100MB；分架构包只带自己那一套，多数手机下 arm64 版即可，体积约为通用包的一半。

### Changed
- 重写各处的软件介绍：桌面条目的 Comment、网页 SEO 描述与分享卡片、PWA 描述、Windows 文件属性。原来这几处写法各不相同，有的堆动词，有的只剩一句世界观标语；现在统一按实际功能直述：是什么、能听什么、在哪能用。

### Fixed
- 固定 Android 签名。此前 CI 每次都在全新 runner 上重新生成 `~/.android/debug.keystore`，等于每次发版换一张证书，用户覆盖安装会报「签名冲突」，只能卸载重装。现在证书随仓库走，签名与 1.1.7 完全一致（SHA-256 `1f2f3775…`，有效期至 2056 年），老用户可以直接升级。

## [1.1.7] - 2026-11-21

### Added
- 下载歌曲时写入艺人元数据：M4A 写入曲名与 UP 主，MediaStore 同步写入 TITLE / ARTIST 两列，系统音乐库与文件管理器能显示曲名和艺人。

### Fixed
- WAV 同时写入 RIFF `LIST/INFO` 和 `id3 ` 两个标签块，兼容不同的播放器。
- 重写 WAV 容器，清掉塞壬文件自带的空 INFO；此前解析器先读到空块会判定整首歌没有标签。

## [1.1.6] - 2026-11-21

### Fixed
- B站下载的音频重封装成标准 M4A，修复部分设备（如华为 Watch GT5）读不到时长、无法播放的问题；重封装失败时保留原文件，不影响下载完成。
- 下载文件名只保留曲名或视频标题，不再加艺人或 UP 主前缀；已有文件仍能被识别，不会被重复下载。

## [1.1.5] - 2026-11-18

### Changed
- Android 三个 ABI 合成一个通用 APK，不用再按架构挑安装包。
- Linux CI 的 apt 步骤加硬超时与重试，避免静默卡到 job 上限。

### Removed
- 移除 Flatpak 打包（Flathub 不接受 AI 辅助开发的软件）。

## [1.1.4] - 2026-11-18

### Changed
- 反代相关提示统一为明日方舟笔调。

### Fixed
- 清理上一轮提示语润色漏下的机器味措辞。
- deb 包 Depends 加备选包名，兼容 Ubuntu 22.04 与 Debian 12。

## [1.1.3] - 2026-11-18

### Added
- 视频页加弹幕开关。

### Changed
- 桌面条目的 Comment 换成正式介绍。
- EdgeOne Pages 部署失败后重试三次。

## [1.1.2] - 2026-11-18

### Changed
- 网页版默认反代指向 `podenco-bili.api.wsmdn.top`，桌面与移动端不受影响。

## [1.1.1] - 2026-11-18

### Added
- 反代服务同时产出 arm64 二进制，镜像改为多架构。

## [1.1.0] - 2026-11-18

### Added
- B站音乐与视频全链路支持，播放层改用 libmpv。

### Fixed
- Linux 构建补装 `libmpv-dev`，解决播放层依赖缺失。
- 抠掉应用图标右侧头发里的黑色残留，Linux 图标纳入仓库。
- Linux CI 的 apt 全程非交互，避免 needrestart 弹窗把 job 挂住。

## [1.0.2] - 2026-11-15

### Changed
- Android APK 按 ABI 拆分，arm64 包从 52MB 降到 18MB。

## [1.0.1] - 2026-11-15

### Added
- 网页版支持下载到用户授权的目录（File System Access）。

## [1.0.0] - 2026-11-15

### Added
- Android 接入系统媒体通知，并加入 vivo 原子随身听白名单。
- 网页版补 SEO 与分享卡片元信息。
- README 补充平台支持说明。

### Fixed
- 点击搜索结果时先收起键盘，迷你播放条不再被遮盖。

## [0.1.5] - 2026-11-15

### Added
- 发布流水线新增 Web 静态构建，并接入 EdgeOne Pages 部署（需在仓库配置 `EDGEONE_API_TOKEN` Secret）。

### Fixed
- Web 产物打包路径少算一层，产物落到工作区外的问题。
- 修正被拼接破坏的 workflow 结构，EO Pages 任务独立、release job 恢复。

## [0.1.4] - 2026-11-15

### Added
- 设置页新增接口代理地址配置：Web 端用它绕开 CORS，OSS 资源直连不走代理。
- 首页右上角收敛为歌单、搜索、溢出菜单。
- Web 端图标换成波登可（favicon / PWA / maskable），manifest 元数据对齐。
- 补 MIT 许可证。

### Changed
- Web 端默认接口指向自建反代 `podenco-music.api.wsmdn.top`，桌面端保持直连官方。
- 设置页保存时自动补 `/api` 前缀，符合反代契约。

### Fixed
- Web 端封面、音频、歌词加载失败：全局设 no-referrer，绕过 hycdn 防盗链对外部 Referer 的拒绝。
- Web 端封面 Provider 按平台分流，改用 NetworkImage（`dart:io` 的 FileImage 在 Web 上不存在）。
- 重试按钮崩溃：setState 箭头闭包返回 Future 触发调试断言，改为块闭包。

## [0.1.3] - 2026-11-14

### Changed
- 撤销 Linux ARM64 构建任务：Flutter 未发布 arm64 Linux SDK，官方清单仅有 x64。

### Fixed
- 修正 Release 产物下载链接里的残留命名。

## [0.1.2] - 2026-11-14

### Added
- 支持 Linux：平台脚手架 + 托盘复用 + CI 构建。

### Changed
- README 补充平台支持说明。

### Fixed
- Linux 构建补 GStreamer 与 libayatana-appindicator3 开发依赖。

## [0.1.1] - 2026-11-14

### Changed
- 应用图标背景从纯白改为透明（ICO / 托盘 / 安卓启动图标 / 封面圆标）。
- README 精简为标题、简介、命令，并补上波登可场景图生成提示词。

## [0.1.0] - 2026-11-14

### Added
- 项目初始化。
- 双平台自动构建与 Release 发布流水线。

[Unreleased]: https://github.com/nomdn/podencoMusic/compare/v1.1.7...HEAD
[1.1.7]: https://github.com/nomdn/podencoMusic/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/nomdn/podencoMusic/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/nomdn/podencoMusic/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/nomdn/podencoMusic/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/nomdn/podencoMusic/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/nomdn/podencoMusic/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/nomdn/podencoMusic/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/nomdn/podencoMusic/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/nomdn/podencoMusic/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/nomdn/podencoMusic/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/nomdn/podencoMusic/compare/v0.1.5...v1.0.0
[0.1.5]: https://github.com/nomdn/podencoMusic/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/nomdn/podencoMusic/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/nomdn/podencoMusic/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/nomdn/podencoMusic/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nomdn/podencoMusic/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nomdn/podencoMusic/releases/tag/v0.1.0
