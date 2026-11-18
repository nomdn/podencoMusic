#!/bin/bash
# 构建 Podenco Music 的 .flatpak 单文件包。
#
# 默认使用官方 Flathub 源（适合 GitHub Actions 等海外环境）：
#   https://dl.flathub.org/repo/
# 国内直连慢时可覆盖环境变量，例如：
#   FLATHUB_URL=https://mirror.sjtu.edu.cn/flathub/ bash build_flatpak.sh
# 首次运行会自动添加用户级 remote，并安装 24.08 Platform/Sdk。
#
# 在仓库根目录运行：bash build_flatpak.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR
W=${W:-$REPO_ROOT}
APP=${APP:-$REPO_ROOT/build/linux/flatpak-app}
OUT=${OUT:-$REPO_ROOT/build/linux/packages}
LINUX_DIR=$REPO_ROOT/build/linux
TARBALL=${TARBALL:-$LINUX_DIR/podenco_music_linux.tar.gz}
BUNDLE_SRC=${BUNDLE_SRC:-$W/src/podenco-music}
# 图标优先用仓库里的 icons/（受版本控制，CI 才有）；其余是历史兜底路径。
ICONS_SRC=${ICONS_SRC:-$REPO_ROOT/icons}
[ -d "$BUNDLE_SRC" ] || BUNDLE_SRC=$LINUX_DIR/x64/release/bundle
[ -d "$ICONS_SRC" ] || ICONS_SRC=$LINUX_DIR/icons
[ -d "$ICONS_SRC" ] || ICONS_SRC=$W/icons

FLATHUB_REMOTE=${FLATHUB_REMOTE:-flathub-ci}
FLATHUB_URL=${FLATHUB_URL:-https://dl.flathub.org/repo/}
RUNTIME_VERSION=${RUNTIME_VERSION:-24.08}

# ------------------------------------------------------------ mirror ----
echo "=== 配置 Flathub 远端：$FLATHUB_URL ==="
if ! flatpak remotes --user | awk 'NR > 1 {print $1}' | grep -qx "$FLATHUB_REMOTE"; then
  GPG_FILE=$(mktemp)
  trap 'rm -f "$GPG_FILE"' EXIT
  curl -fsSL --retry 3 --connect-timeout 20 -o "$GPG_FILE" "${FLATHUB_URL}flathub.gpg"
  flatpak remote-add --user --if-not-exists --gpg-import="$GPG_FILE" "$FLATHUB_REMOTE" "$FLATHUB_URL"
  rm -f "$GPG_FILE"
  trap - EXIT
fi
flatpak remote-modify --user "$FLATHUB_REMOTE" --url="$FLATHUB_URL"

# --------------------------------------------------------------- sdk ----
echo "=== 确保 Flatpak SDK 已安装 ==="
for ref in \
  org.freedesktop.Platform \
  org.freedesktop.Sdk \
  org.freedesktop.Platform.GL.default \
  org.freedesktop.Platform.ffmpeg-full
do
  if ! flatpak info --user "$ref//$RUNTIME_VERSION" >/dev/null 2>&1; then
    echo "  安装 $ref/$RUNTIME_VERSION"
    flatpak install --user -y "$FLATHUB_REMOTE" "$ref/x86_64/$RUNTIME_VERSION"
  fi
done

# ----------------------------------------------------------- libmpv -----
if [ ! -d "$APP/lib" ] || [ -z "$(ls -A "$APP/lib" 2>/dev/null)" ]; then
  echo "=== 收集 libmpv 依赖 ==="
  W="$W" LIBDIR="$APP/lib" bash "$SCRIPT_DIR/collect_libmpv.sh"
fi

# -------------------------------------------------------------- app -----
echo "=== 准备 app 目录 ==="
STAGING=$APP/staging
rm -rf "$STAGING"
mkdir -p "$STAGING/bundle" "$STAGING/icons" "$STAGING/lib"
if [ -d "$BUNDLE_SRC" ]; then
  cp -a "$BUNDLE_SRC/." "$STAGING/bundle/"
else
  [ -f "$TARBALL" ] || { echo "找不到 Flutter bundle: $TARBALL" >&2; exit 1; }
  tar xzf "$TARBALL" -C "$STAGING/bundle" --strip-components=1
fi
[ -f "$STAGING/bundle/podenco_music" ] || {
  echo "bundle 里缺少 podenco_music 可执行文件" >&2; exit 1;
}
cp -a "$APP/lib/." "$STAGING/lib/"

# 图标必须按 hicolor 布局放置
for f in "$ICONS_SRC"/podenco_*.png; do
  [ -f "$f" ] || continue
  size=$(basename "$f" .png | sed 's/podenco_//; s/x.*//')
  mkdir -p "$STAGING/icons/${size}x${size}/apps"
  cp "$f" "$STAGING/icons/${size}x${size}/apps/com.mint.PodencoMusic.png"
done

# Flatpak 的 Desktop Entry 必须调用 manifest 里的 command，图标名必须匹配 app-id
sed -e 's#^Exec=.*#Exec=podenco-music#' \
    -e 's#^Icon=.*#Icon=com.mint.PodencoMusic#' \
    "$SCRIPT_DIR/podenco-music.desktop" \
  > "$STAGING/podenco-music-flatpak.desktop"
cp "$SCRIPT_DIR/podenco-music-wrapper" "$STAGING/podenco-music-wrapper"
cp "$SCRIPT_DIR/com.mint.PodencoMusic.json" "$APP/com.mint.PodencoMusic.json"

# 旧版 flatpak-builder 不支持 dir source 的 destination，打成单个 file source 更稳
tar czf "$APP/payload.tar.gz" -C "$STAGING" .

# ------------------------------------------------------------ build -----
echo "=== flatpak-builder 构建中 ==="
cd "$APP"
# WSL 的 /mnt/d 是 DrvFs，rofiles-fuse 无法在这里挂载
flatpak-builder --user --disable-rofiles-fuse --force-clean --repo=repo builddir com.mint.PodencoMusic.json

# ------------------------------------------------------------ bundle ----
echo "=== 导出 .flatpak ==="
mkdir -p "$OUT"
flatpak build-bundle repo "$OUT/com.mint.PodencoMusic.flatpak" com.mint.PodencoMusic

echo "=== 完成 ==="
ls -lh "$OUT/com.mint.PodencoMusic.flatpak"
echo
echo "安装：flatpak install --user com.mint.PodencoMusic.flatpak"
echo "运行：flatpak run com.mint.PodencoMusic"
