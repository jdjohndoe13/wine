# Building this Wine fork

This repository is a fork of Wine (upstream mirror:
https://github.com/wine-mirror/wine). The fork carries a set of bug fixes
on top of upstream Wine, one commit per fix - see `git log` for the
individual fixes and their commit messages.

This file describes how to build the fork. The rest of the original Wine
documentation (README, docs/ directory) is unchanged from upstream.

## Quick start: build in Docker (recommended)

The supported build runs inside a Docker container based on Debian 10
("buster"). Debian 10 gives the produced binaries a **glibc 2.28 symbol
floor**, so the resulting Wine runs on many older distributions
(Debian 10+, Ubuntu 18.10+, Astra SE, RED OS, ...). The build is
**dual-arch** (new WoW64: `configure --enable-archs=i386,x86_64`), so
the result runs both 64-bit and 32-bit Windows applications.

Requirements: a Linux machine with **Docker** installed (the `docker`
command usable by your user; add yourself to the `docker` group or use
sudo). This is the tested path. No other toolchain is needed on the
host - the compiler, the build dependencies and the mingw-w64
cross-toolchains (x86_64 + i686) all live in the image.

macOS and Windows with Docker Desktop also work (the build runs inside
the Linux container either way), with two caveats:

- **macOS:** the container runs in a VM and the bind-mounted source
  tree is slow to traverse, so the build is noticeably slower than on
  native Linux. Give the Docker VM enough disk (>= 20 GB: the image is
  ~6 GB plus a ~12 GB build dir).
- **Windows:** shell scripts must keep LF line endings. The
  repository's `.gitattributes` pins `*.sh` to LF, but if you have
  `core.autocrlf=true` set globally, force LF in the checkout
  (`git config core.autocrlf false && git rm --cached -r . &&
  git reset --hard`) before running `bash build.sh`, or the build
  fails with `bash\r: bad interpreter`.

```bash
# 1. Get the fork
git clone https://github.com/jdjohndoe13/wine.git
cd wine

# 2. Pull the pre-built build environment (Debian 10 + all build deps
#    + pre-built mingw-w64 gcc 12 / binutils 2.42 cross-toolchains)
docker pull ghcr.io/jdjohndoe13/wine-builder:latest

# 3. Build Wine inside the container.
#    Run it in screen/tmux so an ssh disconnect cannot interrupt it.
WINE_IMAGE=ghcr.io/jdjohndoe13/wine-builder:latest bash build.sh
```

With the pre-built image the build goes straight to `configure && make`
and takes roughly **30-60 minutes** on a modern multicore machine. The
script uses `nproc` jobs; on a RAM-tight box lower it with
`WINE_JOBS` (e.g. `WINE_JOBS=14` on a 16-core / 16 GB machine) so the
link steps do not exhaust memory.

The container installs into the host directory
`${WINE_INSTALL_DIR:-/home/user/wine-inst}` (the outputs are
chowned back to your user at the end). The finished Wine is:

```
${WINE_INSTALL_DIR:-/home/user/wine-inst}/usr/local/bin/wine
${WINE_INSTALL_DIR:-/home/user/wine-inst}/usr/local/lib/...
```

You can run it directly:

```bash
INSTALL=${WINE_INSTALL_DIR:-/home/user/wine-inst}
LD_LIBRARY_PATH=$INSTALL/usr/local/lib $INSTALL/usr/local/bin/wine --version
```

### Optional: package the build as a tarball

To ship the build (e.g. as a `wine.tar.xz` payload), pack the install
tree:

```bash
INSTALL=${WINE_INSTALL_DIR:-/home/user/wine-inst}
( cd "$INSTALL/usr/local" && tar -cf - . | xz -T8 -9e > wine.tar.xz )
```

### Output directories (env overrides)

| Variable              | Default                          | Meaning                          |
|-----------------------|----------------------------------|----------------------------------|
| `WINE_IMAGE`          | `debian:buster`                  | Docker image to build in         |
| `WINE_BUILD_DIR`      | `/home/user/wine-fork-build`     | out-of-tree build dir            |
| `WINE_INSTALL_DIR`    | `/home/user/wine-inst`           | install tree (the deliverable)   |
| `WINE_MINGW_DIR`      | `/home/user/mingw-w64-toolchain` | cross-toolchain cache (only used when the image is NOT pre-built) |
| `WINE_JOBS`           | `nproc`                          | parallel make jobs (lower it on RAM-tight boxes, e.g. `nproc`-2) |

### Building without the pre-built image

`build.sh` works with a plain `debian:buster` image too (the
`WINE_IMAGE` default): it then installs the build dependencies and
builds the mingw-w64 cross-toolchains (x86_64 + i686) inside the
container on the first run (about 2 extra hours; the toolchains are
cached in `$WINE_MINGW_DIR` for later runs). Expect a total of 3-4
hours on the first run.

You can also build the pre-built image yourself
(`tools/docker/Dockerfile`); see the comments at the top of that file.
The image's `WORKDIR`/marker layout (`/opt/dwine/prep-done`) is what
lets `build.sh` detect it and skip the prep stages entirely.

## What `build.sh` does

1. Host-side prefetch of the cross-toolchain sources (only needed when
   the image is not pre-built; git/curl on the host are more reliable
   than inside the container).
2. Applies a gstreamer < 1.16 compat shim to
   `dlls/winegstreamer/wg_transform.c` if it is not already applied
   (buster ships gstreamer 1.14). This touches the source tree; the
   patch is idempotent.
3. Runs the container: `configure --enable-archs=i386,x86_64
   --without-vulkan`, `make -j$(nproc)`, `make install DESTDIR=/install`,
   then sanity checks: it prints the maximum `GLIBC_*` symbol version
   referenced by the produced ELF tree (must be <= 2.28) and runs
   `wine --version` inside the container.
4. Chowns the outputs back to the invoking user.

Re-running `build.sh` is safe: it rebuilds Wine from scratch each time
and keeps the toolchain cache.

## Notes

- Vulkan is disabled (`--without-vulkan`): buster's Vulkan headers are
  too old for current Wine.
- The build is dual-arch (new WoW64): `--enable-archs=i386,x86_64`
  produces the x86_64 Unix side plus the 32-bit PE side
  (`lib/wine/i386-windows/`), so 32-bit Windows apps run as well.
- The `dwrite` layout tests sanity check from the upstream dwrite
  fixes: see the fix commits in `dlls/dwrite/` for the specific
  regression tests.
