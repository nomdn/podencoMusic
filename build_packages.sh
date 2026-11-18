#!/bin/bash
# 把 Flutter Linux bundle 打包成 deb / rpm / Arch(.pkg.tar.zst) 三种格式。
# 在仓库根目录（本脚本所在目录）运行：bash build_packages.sh
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR
if [ -z "${W:-}" ]; then
  # 默认在临时目录里搭 staging：避免 WSL DrvFs 的 0777 权限和仓库污染
  W=$(mktemp -d)
  CLEAN_W=1
else
  CLEAN_W=0
fi
cleanup() { [ "$CLEAN_W" = 1 ] && rm -rf "$W"; }
trap cleanup EXIT

# 本地历史用法：$W/src/podenco-music；CI/全新检出直接用 Flutter 构建产物
if [ -z "${SRC:-}" ] || [ ! -d "${SRC:-}" ]; then
  if [ -d "$W/src/podenco-music" ]; then
    SRC=$W/src/podenco-music
  else
    SRC=$REPO_ROOT/build/linux/x64/release/bundle
  fi
fi
if [ ! -d "$SRC" ] && [ -f "$REPO_ROOT/build/linux/podenco_music_linux.tar.gz" ]; then
  mkdir -p "$W/src/podenco-music"
  tar xzf "$REPO_ROOT/build/linux/podenco_music_linux.tar.gz" \
    -C "$W/src/podenco-music" --strip-components=1
  SRC=$W/src/podenco-music
fi
[ -d "$SRC" ] || { echo "找不到 Flutter Linux bundle: $SRC" >&2; exit 1; }

OUT=${OUT:-$REPO_ROOT/build/linux/packages}
DESKTOP=${DESKTOP:-$W/podenco-music.desktop}
[ -f "$DESKTOP" ] || DESKTOP=$SCRIPT_DIR/podenco-music.desktop
ICONS=${ICONS:-$W/icons}
[ -d "$ICONS" ] || ICONS=$REPO_ROOT/build/linux/icons
[ -d "$ICONS" ] || { echo "找不到图标目录: $ICONS" >&2; exit 1; }

NAME=podenco-music
ARCH=amd64
PREFIX=/opt/podenco-music

# 版本号唯一来源是 pubspec.yaml 的 `version: 1.0.2+4`。
# 包格式不接受 `+build` 后缀，所以截掉 `+` 之后那段；
# 想手工指定时用 `VERSION=1.0.3 bash build_packages.sh` 覆盖。
if [ -z "${VERSION:-}" ]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$REPO_ROOT/pubspec.yaml" \
    | head -1 | tr -d '[:space:]' | cut -d'+' -f1)
fi
case "$VERSION" in
  ''|*[!0-9A-Za-z.+~-]*)
    echo "版本号非法（取到 '$VERSION'）：来源是 pubspec.yaml 的 version 字段，" \
         "或显式传入的 VERSION 环境变量" >&2
    exit 1
    ;;
esac

mkdir -p "$W" "$OUT"
cd "$W"

# ---------------------------------------------------------------- deb ----
echo "=== 构建 .deb ==="
DEB=$W/debroot
rm -rf "$DEB"
mkdir -p "$DEB/DEBIAN" \
         "$DEB/opt/podenco-music" \
         "$DEB/usr/share/applications" \
         "$DEB/usr/share/icons/hicolor"

cp -r "$SRC"/. "$DEB/opt/podenco-music/"
cp "$DESKTOP" "$DEB/usr/share/applications/$NAME.desktop"
for f in "$ICONS"/*.png; do
  size=$(basename "$f" .png | sed 's/podenco_//; s/x.*//')
  mkdir -p "$DEB/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$f" "$DEB/usr/share/icons/hicolor/${size}x${size}/apps/podenco.png"
done

INSTALLED=$(du -sk "$DEB" | awk '{print $1}')
cat > "$DEB/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: multimedia
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED
Maintainer: Podenco Music <noreply@localhost>
Description: 听歌、看B站视频与弹幕的桌面客户端
 Flutter 桌面应用，支持 B站 音乐播放、视频与高级弹幕渲染。
Depends: libgtk-3-0, libayatana-appindicator3-1, libdbusmenu-gtk3-4, libmpv2, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav, libasound2t64, libpulse0
EOF
# DrvFs/共享目录常继承 0777，dpkg-deb 会拒绝，这里显式收紧权限
chmod 755 "$DEB/DEBIAN"
chmod 644 "$DEB/DEBIAN/control"
dpkg-deb --build --root-owner-group "$DEB" "$OUT/${NAME}_${VERSION}_${ARCH}.deb" >/dev/null
echo "  产物: $OUT/${NAME}_${VERSION}_${ARCH}.deb"

# ---------------------------------------------------------------- rpm ----
echo "=== 构建 .rpm ==="
RPMBUILD=$W/rpmbuild
rm -rf "$RPMBUILD"
mkdir -p "$RPMBUILD"/{BUILD,BUILDROOT,RPMS,SPECS,SOURCES,SRPMS}
# 源归档：tar 到 SPECS 同级，spec 里用相对路径
tar czf "$RPMBUILD/SOURCES/podenco-music.tar.gz" -C "$SRC" .

cat > "$RPMBUILD/SPECS/podenco-music.spec" <<EOF
Name:           $NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        听歌、看B站视频与弹幕的桌面客户端
License:        Proprietary
URL:            https://github.com/podenco/podenco_music
Source0:        podenco-music.tar.gz
BuildArch:      x86_64
Requires:       gtk3
Requires:       libayatana-appindicator3
Requires:       mpv-libs
Requires:       gstreamer1-plugins-base
Requires:       gstreamer1-plugins-good
Requires:       pulseaudio-libs
%description
Flutter 桌面应用，支持 B站 音乐播放、视频与高级弹幕渲染。
%install
mkdir -p %{buildroot}$PREFIX
mkdir -p %{buildroot}%{_datadir}/applications
mkdir -p %{buildroot}%{_datadir}/icons/hicolor
cp -a $W/rpmbuild/EXTRACTED/. %{buildroot}$PREFIX/
install -m 644 $DESKTOP %{buildroot}%{_datadir}/applications/$NAME.desktop
%files
$PREFIX
%{_datadir}/applications/$NAME.desktop
EOF
# rpmbuild 的 %install 不自动解包，先把 bundle 解到固定目录供 spec 用绝对路径引用
mkdir -p "$RPMBUILD/EXTRACTED"
tar xzf "$RPMBUILD/SOURCES/podenco-music.tar.gz" -C "$RPMBUILD/EXTRACTED"
rpmbuild -bb --nodeps \
  --define "_topdir $RPMBUILD" \
  "$RPMBUILD/SPECS/podenco-music.spec" >/dev/null 2>&1 || {
  echo "  rpmbuild 失败，打印详细错误:" >&2
  rpmbuild -bb --nodeps --define "_topdir $RPMBUILD" \
    "$RPMBUILD/SPECS/podenco-music.spec" 2>&1 | tail -25 >&2
  exit 1
}
find "$RPMBUILD/RPMS" -name "*.rpm" -exec cp {} "$OUT/" \;
echo "  产物: $(find "$OUT" -name '*.rpm' -printf '%f\n' | head -1)"

# ------------------------------------------------------------ Arch -------
echo "=== 构建 .pkg.tar.zst (Arch) ==="
ARCHROOT=$W/archroot
rm -rf "$ARCHROOT"
mkdir -p "$ARCHROOT/opt/podenco-music" \
         "$ARCHROOT/usr/share/applications" \
         "$ARCHROOT/usr/share/icons/hicolor"
cp -r "$SRC"/. "$ARCHROOT/opt/podenco-music/"
cp "$DESKTOP" "$ARCHROOT/usr/share/applications/$NAME.desktop"
for f in "$ICONS"/*.png; do
  size=$(basename "$f" .png | sed 's/podenco_//; s/x.*//')
  mkdir -p "$ARCHROOT/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$f" "$ARCHROOT/usr/share/icons/hicolor/${size}x${size}/apps/podenco.png"
done
cat > "$ARCHROOT/.PKGINFO" <<EOF
pkgname = $NAME
pkgver = $VERSION-1
pkgdesc = 听歌、看B站视频与弹幕的桌面客户端
url = https://github.com/podenco/podenco_music
builddate = $(date +%s)
packager = Podenco Music <noreply@localhost>
size = $(du -sb "$ARCHROOT" | awk '{print $1}')
arch = x86_64
license = custom
depend = gtk3
depend = libayatana-appindicator3
depend = mpv
depend = gstreamer
depend = gst-plugins-good
depend = gst-libav
depend = alsa-lib
depend = libpulse
EOF
# tar.zst：.PKGINFO 必须在归档根
(cd "$ARCHROOT" && tar --use-compress-program=zstd -cf "$OUT/${NAME}-${VERSION}-1-x86_64.pkg.tar.zst" .)
echo "  产物: $OUT/${NAME}-${VERSION}-1-x86_64.pkg.tar.zst"

echo "=== 全部产物 ==="
ls -lh "$OUT"
