# Podenco Music

塞壬唱片（[monster-siren.hypergryph.com](https://monster-siren.hypergryph.com/music)）的非官方客户端，
Flutter 写的，一套代码跑 Windows / Android。

界面全部用 Material 3 默认组件，没有自定义配色和圆角 —— 只给了一颗琥珀色种子色。

## 命令

```bash
# 桌面（改代码保存后按 r 热重载最快）
flutter run -d windows

# 安卓模拟器
flutter emulators --launch Pixel_8
flutter run

# 出安装包
flutter build apk --release
```
