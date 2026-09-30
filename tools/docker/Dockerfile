# ---------------------------------------------------------------------------
# Dockerfile -- pre-built build environment for build.sh
#               (x86_64-only Wine, Dr.Explain Linux bundle)
#
# Contains:
#   * Debian 10 (buster) -- glibc 2.28 floor for portability to old distros
#     (Astra SE 1.7/1.8, RED OS, MSVSphere 9, ...)
#   * all wine build dependencies (desktop/X11, audio, gstreamer 1.14, ...)
#   * the mingw-w64 (gcc 12 / binutils 2.42) cross-toolchain, pre-built
#   * marker /opt/dwine/prep-done -- build.sh detects it and skips the
#     apt install + toolchain build stages entirely
#
# Build the image ONCE (on a Linux box with docker; the context must contain
# mingw/ prepared by build.sh's host-side prefetch: mingw/mwb.sh + src/):
#     docker build -t drexplain-wine-build:x64 .
# Then build Wine at any time (from a checkout of this repository):
#     WINE_IMAGE=drexplain-wine-build:x64 bash build.sh
# A wine rebuild then runs straight to `configure && make` (~10-30 min
# instead of ~2.5-3.5 h from a fresh debian:buster + 1 h toolchain build).
# Sources and outputs stay outside the image (bind mounts; never bake the
# wine tree into the image).
# ---------------------------------------------------------------------------
FROM debian:buster

# Debian 10 is EOL: use the archive with validity checks off (frozen forever;
# a non-moving package set is a feature here, not a bug).
RUN rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true && \
    printf 'deb [trusted=yes] http://archive.debian.org/debian buster main contrib non-free\n\
deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main contrib non-free\n' > /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99buster-archive

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gcc g++ make flex bison gettext texinfo gawk pkg-config ccache curl patch \
      libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev \
      libxcursor-dev libxfixes-dev libxcomposite-dev libxinerama-dev \
      libxxf86vm-dev libxt-dev libxmu-dev libxkbfile-dev \
      libgl1-mesa-dev libegl1-mesa-dev libglu1-mesa-dev \
      libfontconfig1-dev libfreetype6-dev libunwind-dev \
      libasound2-dev libpulse-dev libdbus-1-dev libudev-dev \
      libgnutls28-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      libavcodec-dev libavformat-dev libavutil-dev \
      libopenal-dev libsdl2-dev \
      libusb-1.0-0-dev libpcap0.8-dev libv4l-dev libcapi20-dev \
      libcups2-dev libgphoto2-dev libkrb5-dev libldap2-dev unixodbc-dev \
      libpcsclite-dev \
      m4 bzip2 ca-certificates git wget xz-utils binutils \
 && rm -rf /var/lib/apt/lists/*

# Cross-toolchain: Kron4ek's mingw-w64-build + pre-fetched sources come from
# the build context (same layout the runtime cache uses: mwb.sh + src/),
# so the image build needs no network flakiness beyond the apt layer.
COPY mingw /opt/mingw-w64
RUN cd /opt/mingw-w64 && bash mwb.sh --cached-sources --keep-artifacts \
        --root=/opt/mingw-w64 --prefix=/opt/mingw-w64 x86_64 \
    && rm -rf /opt/mingw-w64/_mw-build /opt/mingw-w64/_mwb \
 && test -x /opt/mingw-w64/bin/x86_64-w64-mingw32-gcc

ENV PATH=/opt/mingw-w64/bin:$PATH
RUN mkdir -p /build /install /opt/dwine && touch /opt/dwine/prep-done \
 && x86_64-w64-mingw32-gcc --version | head -1

WORKDIR /build
