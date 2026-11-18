#!/bin/bash
# 收集 libmpv.so.2 及其所有非系统核心依赖，供 Flatpak 打包用。
# Flatpak 沙箱里 org.freedesktop.Platform 提供 GTK/GStreamer/ffmpeg 基础库，
# 但不提供 libmpv —— 所以把系统 libmpv 及其私有依赖一起塞进 /app/lib。
set -euo pipefail

W=${W:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
LIBDIR=${LIBDIR:-$W/build/linux/flatpak-app/lib}
mkdir -p "$LIBDIR"

echo "=== 递归收集 libmpv 依赖 ==="
# 只收集 /usr/lib 下的 .so，排除 glibc/gcc 等运行时自带的（Platform 提供）
python3 - "$LIBDIR" <<'PY'
import subprocess, os, shutil, sys

libdir = sys.argv[1]
os.makedirs(libdir, exist_ok=True)

# 运行时平台自带的库前缀（不要重复打包）
SKIP = (
    'libc.so', 'libm.so', 'libdl.so', 'libpthread.so', 'librt.so',
    'libgcc_s.so', 'libstdc++.so', 'libz.so', 'libglib-2.0.so',
    'libgobject-2.0.so', 'libgthread-2.0.so', 'libgmodule-2.0.so',
    'libgio-2.0.so', 'libcairo.so', 'libpango', 'libgtk-3.so',
    'libgdk-3.so', 'libX11.so', 'libxcb.so', 'libfontconfig.so',
    'libfreetype.so', 'libexpat.so', 'libffi.so', 'libpcre',
    'libgstreamer', 'libgst', 'libav', 'libsw', 'libFLAC.so',
    'libogg.so', 'libvorbis', 'libopus.so', 'libasound.so',
    'libpulse.so', 'libdbus-1.so', 'libsystemd.so', 'libudev.so',
    'libdrm.so', 'libEGL.so', 'libGL', 'libgbm.so', 'libwayland',
    'libepoxy.so', 'libatspi', 'libatk', 'libharfbuzz.so',
    'libpixman', 'libpng', 'libjpeg', 'libintl.so', 'libbind9',
    'libselinux.so', 'libcap.so', 'libaudit.so', 'liblzma.so',
    'libbz2.so', 'libzstd.so', 'libbrotli', 'libgmp.so',
    'libnettle.so', 'libhogweed.so', 'libgnutls.so', 'libidn2.so',
    'libunistring.so', 'libtasn1.so', 'libp11-kit.so',
)

visited = set()
def collect(path):
    if path in visited or not os.path.exists(path):
        return
    visited.add(path)
    name = os.path.basename(path)
    if name.startswith(SKIP):
        return
    shutil.copy2(path, os.path.join(libdir, name))
    try:
        out = subprocess.check_output(['ldd', path], stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return
    for line in out.splitlines():
        if '=> /' in line:
            dep = line.split('=>', 1)[1].strip().split()[0]
            if dep.startswith('/usr/lib'):
                collect(dep)

collect('/usr/lib/x86_64-linux-gnu/libmpv.so.2')
libs = sorted(os.listdir(libdir))
print('收集到 %d 个库:' % len(libs))
for l in libs[:30]:
    print('  ', l)
if len(libs) > 30:
    print('   ... 共 %d 个' % len(libs))
PY

echo "=== 大小 ==="
du -sh "$LIBDIR"
