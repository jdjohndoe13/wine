#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh -- build the x86_64-only Wine (this fork) inside Dockerized
#             Debian 10 (buster), for the Dr.Explain Linux bundle.
#
# Why Debian 10 : glibc 2.28 floor -- every produced ELF binary links only
#                 against glibc symbols <= 2.28, so the bundle also runs on
#                 older distros (Astra SE 1.7/1.8, RED OS, MSVSphere 9, ...).
# Why x86_64    : Dr.Explain 7.2 (Inno Setup 7, SetupArchitecture=x64) and
#                 DrExplain.exe are 64-bit-only PEs; no 32-bit PE is ever
#                 executed, so the dual-arch (new-WoW64) tree is not needed
#                 and the bundled payload shrinks by ~25 percent.
# How           : /src/configure --enable-win64  (single-arch x86_64 -- a
#                 plain ./configure would build the 32-bit variant!). The PE
#                 side is built with the mingw-w64 (gcc 12 / binutils 2.42)
#                 cross-toolchain from Kron4ek's mingw-w64-build script,
#                 cached in $MINGW so later wine builds skip the ~1 h
#                 toolchain build. Vulkan is disabled (buster's headers are
#                 too old for wine 10+; Dr.Explain does not use Vulkan).
#                 Debian 10 is EOL: apt is pointed at archive.debian.org
#                 with validity checks off. ALL toolchain resources are
#                 pre-fetched on the HOST (git/curl are reliable there);
#                 the container runs the toolchain script with
#                 --cached-sources and its work area inside the persistent
#                 bind mount, so transient container-side network failures
#                 cannot abort the 2-3 h build.
#
# Outputs
#   $BUILD/wine/            out-of-tree build dir
#   $INSTALL/usr/local/     installed tree -- point the bundle assembler
#                           (d3-aspkg.sh INST=) at this path
#
# Re-entrancy : safe to re-run; wine rebuilds from scratch each time, the
#               cross-toolchain and its sources are kept. Outputs are
#               chown'ed back to the invoking user at the end (the first
#               run must not leave root-owned files on the host).
#
# Usage (Linux box with docker, inside a checkout of this repository):
#   Recommended: run inside screen/tmux so an ssh disconnect cannot
#                interrupt the 2-3 h build:
#     screen -dmS winebuild bash build.sh
#     screen -r winebuild          # watch live (Ctrl+A D to detach)
#   Or detached:
#     nohup bash build.sh > /tmp/d10wine.log 2>&1 &
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
IMAGE="${WINE_IMAGE:-debian:buster}"
BUILD="${WINE_BUILD_DIR:-/home/user/wine-fork-build-x64only}"
INSTALL="${WINE_INSTALL_DIR:-/home/user/wine-inst-x64only}"
MINGW="${WINE_MINGW_DIR:-/home/user/mingw-w64-toolchain}"
JOBS="$(nproc)"

[ -x "$REPO_ROOT/configure" ] || {
  echo "ERROR: run this script from a checkout of the wine fork (./configure missing)"; exit 1; }
command -v docker > /dev/null || { echo "ERROR: docker not available on this host"; exit 1; }

mkdir -p "$BUILD" "$INSTALL" "$MINGW"
rm -rf "$BUILD/wine" 2>/dev/null || true
if [ -e "$BUILD/wine" ]; then
  # previous run died before its chown-back: files are owned by the container
  # uid, the host cannot remove them -- let the container do it
  echo "=== pre-clean: stale build dir owned by container uid; cleaning in container ==="
  docker run --rm -v "$BUILD":/build "$IMAGE" rm -rf /build/wine
  [ -e "$BUILD/wine" ] && { echo "ERROR: could not clean $BUILD/wine"; exit 1; } || true
fi

# --- HOST-SIDE prefetch of the cross-toolchain script and sources ---
# The Kron4ek mingw-w64-build script normally downloads everything itself,
# but in-container TLS transfers proved untrustworthy; git/curl work reliably
# on the host. Layout expected by the script (--cached-sources):
#   $MINGW/src/mingw-w64  $MINGW/src/binutils  $MINGW/src/gcc  $MINGW/src/config.guess
if [ ! -s "$MINGW/mwb.sh" ]; then
  rm -f "$MINGW/mwb.sh"
  echo "=== fetching mingw-w64-build (host side) ==="
  curl -fsSL --retry 5 \
        https://raw.githubusercontent.com/Kron4ek/Wine-Builds/10.20/mingw-w64-build \
        -o "$MINGW/mwb.sh" \
  || wget -q https://raw.githubusercontent.com/Kron4ek/Wine-Builds/10.20/mingw-w64-build \
        -O "$MINGW/mwb.sh"
  [ -s "$MINGW/mwb.sh" ] || { echo "ERROR: cannot fetch mingw-w64-build"; exit 1; }
fi

fetch_git() {
  local url="$1" branch="$2" dst="$3" i
  if [ -d "$dst/.git" ]; then echo "    already cached: $dst"; return 0; fi
  for i in 1 2 3; do
    git clone --depth 1 -b "$branch" "$url" "$dst" && return 0
    echo "    clone attempt $i failed, retrying: $url"; rm -rf "$dst" 2>/dev/null || true; sleep 10
  done
  echo "ERROR: cannot clone $url"; exit 1
}

if [ ! -d "$MINGW/src/mingw-w64" ] || [ ! -d "$MINGW/src/binutils" ] \
   || [ ! -d "$MINGW/src/gcc" ] || [ ! -s "$MINGW/src/config.guess" ]; then
  echo "=== pre-fetching cross-toolchain sources on the host (retries) ==="
  mkdir -p "$MINGW/src"
  fetch_git https://github.com/mingw-w64/mingw-w64.git master "$MINGW/src/mingw-w64"
  fetch_git https://github.com/bminor/binutils-gdb.git binutils-2_42-branch "$MINGW/src/binutils"  # github mirror: sourceware flaked with HTTP/2 stream errors
  fetch_git https://github.com/gcc-mirror/gcc.git releases/gcc-12 "$MINGW/src/gcc"
  if [ -s "$MINGW/src/config.guess" ]; then
    echo "    config.guess already cached"
  else
    cp "$MINGW/src/gcc/config.guess" "$MINGW/src/config.guess" 2>/dev/null || true
  fi
  if [ ! -s "$MINGW/src/config.guess" ]; then
    curl -fsSL --retry 5 \
      "https://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD" \
      -o "$MINGW/src/config.guess" || true
    [ -s "$MINGW/src/config.guess" ] || { echo "ERROR: cannot fetch config.guess"; exit 1; }
  fi
  echo "=== fetching gcc prerequisites (gmp/mpfr/mpc/isl) on the host ==="
  deps=0
  for i in 1 2 3; do
    if ( cd "$MINGW/src/gcc" && ./contrib/download_prerequisites ); then deps=1; break; fi
    echo "gcc prerequisite fetch attempt $i failed; sleeping 30s"
    sleep 30
  done
  [ "$deps" = 1 ] || { echo "ERROR: gcc download_prerequisites failed"; exit 1; }
fi

echo "=== applying gstreamer-1.14 compat shim (if needed) ==="
if ! grep -q "shim for gstreamer < 1.16" "$REPO_ROOT/dlls/winegstreamer/wg_transform.c"; then
  command -v patch >/dev/null || { echo "ERROR: host lacks patch(1)"; exit 1; }
  patch -d "$REPO_ROOT" -p1 --batch <<'WGSHIM'
--- a/dlls/winegstreamer/wg_transform.c
+++ b/dlls/winegstreamer/wg_transform.c
@@ -40,5 +40,20 @@
 #include "unix_private.h"
 
+/* shim for gstreamer < 1.16 (Debian 10 ships 1.14): implement
+ * gst_video_format_info_component() locally, as upstream does. */
+#if !GST_CHECK_VERSION(1, 16, 0)
+static void
+gst_video_format_info_component(const GstVideoFormatInfo *finfo, gint plane,
+        gint components[GST_VIDEO_MAX_COMPONENTS])
+{
+    gint c, i = 0;
+
+    for (c = 0; c < finfo->n_components; c++)
+        if (plane == finfo->plane[c])
+            components[i++] = c;
+    components[i] = -1;
+}
+#endif
 #define GST_SAMPLE_FLAG_WG_CAPS_CHANGED (GST_MINI_OBJECT_FLAG_LAST << 0)
 
 /* This GstElement takes buffers and events from its sink pad, instead of pushing them
WGSHIM
  grep -q "shim for gstreamer < 1.16" "$REPO_ROOT/dlls/winegstreamer/wg_transform.c" \
    || { echo "ERROR: shim patch failed to apply"; exit 1; }
else
  echo "    already applied"
fi

echo "=== wine x64-only build in docker ($IMAGE) ==="
echo "    source : $REPO_ROOT"
echo "    build  : $BUILD/wine"
echo "    install: $INSTALL/usr/local"
echo "    mingw  : $MINGW (persistent cross-toolchain cache)"
echo "    jobs   : $JOBS"

# Pre-built image mode: WINE_IMAGE may point at an image built from
# tools/docker/Dockerfile (deps + cross-toolchain baked in, marker file
# /opt/dwine/prep-done). In that mode the $MINGW bind mount is skipped --
# mounting it would shadow the baked-in toolchain.
PREPPED=0
if docker run --rm "$IMAGE" test -f /opt/dwine/prep-done 2>/dev/null; then
  PREPPED=1
  echo "=== image $IMAGE is pre-built: apt + toolchain steps will be skipped ==="
fi

docker run --rm -i \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e HOST_JOBS="$JOBS" \
  -v "$REPO_ROOT":/src \
  -v "$BUILD":/build \
  -v "$INSTALL":/install \
  $([ "$PREPPED" = 0 ] && echo -v "$MINGW":/opt/mingw-w64) \
  -w /build \
  "$IMAGE" bash -s <<'EOS'
set -euo pipefail
trap 'rc=$?; echo "=== CONTAINER_ERROR rc=$rc at $(date -Iseconds) ===" >&2; exit $rc' ERR
echo "--- container start $(date -Iseconds), debian $(cat /etc/debian_version), uid=$(id -u) ---"

# ---- 1-3) dependency install + mingw-w64 cross-toolchain ----
# In a pre-built image (tools/docker/Dockerfile) both are baked in and the
# work reduced to the wine build itself.
if [ -f /opt/dwine/prep-done ]; then
  echo "=== pre-built image: deps and cross-toolchain are already present ==="
else
# ---- 1) Debian 10 is EOL: use the archive, validity checks off ----
rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true
cat > /etc/apt/sources.list <<'SL'
deb [trusted=yes] http://archive.debian.org/debian buster main contrib non-free
deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main contrib non-free
SL
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99buster-archive
apt-get update

# ---- 2) build dependencies (wine 11 + desktop stack + toolchain build) ----
PKGS='gcc g++ make flex bison gettext texinfo gawk pkg-config ccache curl
      libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev
      libxcursor-dev libxfixes-dev libxcomposite-dev libxinerama-dev
      libxxf86vm-dev libxt-dev libxmu-dev libxkbfile-dev
      libgl1-mesa-dev libegl1-mesa-dev libglu1-mesa-dev
      libfontconfig1-dev libfreetype6-dev libunwind-dev
      libasound2-dev libpulse-dev libdbus-1-dev libudev-dev
      libgnutls28-dev
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
      libavcodec-dev libavformat-dev libavutil-dev
      libopenal-dev libsdl2-dev
      libusb-1.0-0-dev libpcap0.8-dev libv4l-dev libcapi20-dev
      libcups2-dev libgphoto2-dev libkrb5-dev libldap2-dev unixodbc-dev
      libpcsclite-dev
      m4 bzip2 ca-certificates git wget xz-utils binutils'
if ! apt-get install -y --no-install-recommends $PKGS; then
  echo "batch apt install failed -- retrying package-by-package (optionals may be skipped)"
  for p in $PKGS; do
    apt-get install -y --no-install-recommends "$p" || echo "APT-SKIP $p"
  done
fi

# ---- 3) mingw-w64 cross-toolchain (x86_64), cached across runs ----
# kron4ek's script requires: g++ flex bison git makeinfo m4 bzip2 curl make diff
# (all installed above). Sources were pre-fetched on the host; run with
# --cached-sources. --root keeps src/bld/build.log inside the persistent
# mount; --prefix installs the cross-compiler into /opt/mingw-w64/bin;
# --keep-artifacts keeps sources for future runs.
if [ ! -x /opt/mingw-w64/bin/x86_64-w64-mingw32-gcc ]; then
  echo "=== cross-toolchain not cached yet -- building once (~1 h) ==="
  mkdir -p /opt/_mwb
  cd /opt/_mwb
  bash /opt/mingw-w64/mwb.sh --cached-sources --keep-artifacts \
       --root=/opt/mingw-w64 --prefix=/opt/mingw-w64 x86_64
  if [ ! -x /opt/mingw-w64/bin/x86_64-w64-mingw32-gcc ]; then
    probe="$(find /opt/mingw-w64 -type f -name x86_64-w64-mingw32-gcc 2>/dev/null | head -1)"
    if [ -z "$probe" ]; then
      echo "ERROR: cross-toolchain was built but the compiler binary was not found"; exit 1
    fi
    echo "WARN: unexpected toolchain layout; gcc found at: $probe"
  fi
  cd /
  rm -rf /opt/_mwb
fi
fi
export PATH="/opt/mingw-w64/bin:$PATH"
x86_64-w64-mingw32-gcc --version | head -1

# ---- 4) configure: SINGLE-ARCH x86_64 (plain ./configure = 32-bit build!) ----
mkdir -p /build/wine
cd /build/wine
/src/configure --enable-win64 --without-vulkan

# ---- 5) build + install ----
make -j"$HOST_JOBS"
make install DESTDIR=/install

# ---- 6) sanity checks ----
W=/install/usr/local/bin/wine
[ -x "$W" ] || { echo "ERROR: no wine binary in the install tree"; exit 1; }
ls /install/usr/local/bin
echo "--- glibc symbol floor of the produced ELF tree (required: 2.28 or lower) ---"
GLIBC_MAX=$(find /install/usr/local/lib /install/usr/local/bin -type f \( -name '*.so' -o -name '*.so.*' -o -name 'wine' -o -name 'wineserver' \) -print0 | xargs -0 -n16 objdump -T 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1)
echo "GLIBC_MAX=$GLIBC_MAX"
echo "--- wine --version inside this same glibc-2.28 container (no X needed) ---"
LD_LIBRARY_PATH=/install/usr/local/lib /install/usr/local/bin/wine --version

# ---- 7) give the outputs back to the invoking user ----
chown -R "$HOST_UID:$HOST_GID" /build /install
[ -f /opt/dwine/prep-done ] || chown -R "$HOST_UID:$HOST_GID" /opt/mingw-w64
echo "--- container done $(date -Iseconds) ---"
echo BUILD_OK
EOS

rc=$?
echo "=== docker run rc=$rc ==="
[ "$rc" -eq 0 ] || { echo "BUILD_FAILED (see the log above)"; exit "$rc"; }
echo "=== build.sh done; install tree: $INSTALL/usr/local ==="
