# Build wine (dwrite-hittest-fixes) on a fresh Ubuntu 26.04 and run Dr.Explain

These steps were performed as written on a fresh Ubuntu 26.04 LTS machine
(`ubu`).

This branch contains three wine patches:

| Commit | Bug | What it fixes |
|---|---|---|
| `d1d9603b1be` | bug 59487 | Guard `HitTestTextRange`/`HitTestPoint` against empty AssembleDisplayMath text regions |
| `132dfec64d6` | bug 59489 | Fix `HitTestTextRange` (real trace shows it is queried by real apps) |
| `f2874473754` | bug 59488 | Fix caret placement of `HitTestPoint` authoritative trailing hypothesis |

Base: `6880117619afdf62b4ccc40a8c6268c86613131f` (wine-mirror master, 2026-09-26).

## 1. Install build prerequisites

    sudo apt update
    sudo apt install -y build-essential flex bison gettext gcc-mingw-w64

Optional (adds C++ PE support â€” slightly more PE tests get built; the build
also works without it):

    sudo apt install -y g++-mingw-w64

## 2. Clone the branch

    git clone -b dwrite-hittest-fixes https://github.com/jdjohndoe13/wine.git
    cd wine

## 3. Build (out-of-tree, both architectures)

    mkdir wine-fork-build
    cd wine-fork-build
    ../configure --enable-archs=i386,x86_64
    make -j$(nproc)

`make` takes roughly 15-20 minutes on a modern 16-core machine (it uses about
12 GB of disk in the build dir).

## 4. Sanity-check the build

    WINEPREFIX=/tmp/test-prefix ./wine ./dlls/dwrite/tests/x86_64-windows/dwrite_test.exe layout

Expected: no failures (75846 layout tests executed, 44 todo, 0 failures, 1
skipped on our fresh box; a box with `g++-mingw-w64` installed runs more of
them). Remove `/tmp/test-prefix` afterwards.

## 5. Get the Dr.Explain installer

Dr.Explain 7.2 build 1394 lives here:

    https://www.drexplain.com/download/getfile.php?product=drexplain&tg=

Notes:

- Do NOT try `wget`/`curl` on that URL from the Linux box: the download is
  served by `downloads.drexplain.com` and the CDN terminates non-browser TLS
  connections. Download it in a normal browser instead.
- The downloaded file is named `drexplain_7_2_1394.exe` (276,278,888 bytes).
- If you downloaded on Windows/another machine, copy it to the Linux box,
  e.g.:

        scp drexplain_7_2_1394.exe ubu:/tmp/drexplain-setup.exe

  Its sha256 is
  `f6fadf03d4c8827af7edf2bb82d5e20f55bf87bb53bfbf52207980954b0c5814`.

## 6. Create a fresh wine prefix

From `wine-fork-build`:

    export DISPLAY=:0
    WINEPREFIX=$HOME/drex-fork-pref ./wine wineboot -i

(use `DISPLAY=${DISPLAY:-:0}` if the shell does not have `DISPLAY` set).

## 7. Install Dr.Explain under the new build

Run the installer with the standard Gecko/Mono overrides so no pop-ups
interrupt the wizard:

    WINEPREFIX=$HOME/drex-fork-pref WINEDLLOVERRIDES="mscoree,mshtml=" \
        ./wine /tmp/drexplain-setup.exe

The setup wizard:

1. Language dialog: OK (English).
2. Welcome: Next.
3. License: select "I accept the agreement", Next.
4. Destination / Start-menu / "Ready to Install": keep defaults, Next.
5. "Ready to Install": Install.
6. On the **"Additional components"** page: **UNCHECK
   `"Install Microsoft HTML Help Workshop 1.32 to create CHM files"`**
   (the CHH/HHW download lacks a working installer under wine; skip it here
   per user instructions).
7. Next, then Finish (leaves "Launch Dr.Explain" checked and starts the app).

The app is installed to `C:\Program Files\DrExplain` in the prefix.

## 7a. Silent installation (optional, verified)

The installer is an Inno Setup package and supports the standard silent
flags. Two facts matter (checked against the installer script and verified
empirically under this wine build):

1. Plain `/VERYSILENT` finishes unattended (exit code 0, no app auto-launch:
   the `[Run]` entry is `skipifsilent`) **but it silently installs HTML Help
   Workshop anyway**. The HHW offer is not an Inno `[Tasks]` entry â€” it is a
   dynamically created `[Code]` page whose checkbox is added and defaulted
   to checked whenever the freshly installed `DrExplain.exe -FillHHWPath`
   probe does not find an HHW install, and the MSI then runs with `/quiet`.
   There is no `/TASKS=` switch to skip it.
2. The skip logic trusts a pre-populated registry value
   (`HKCU\Software\Indigo Byte Systems\Dr.Explain\CHMExport`, value
   `MSHHW Path`) as long as `<value>\hhc.exe` exists
   (`CatchNDoc/Helper.cpp: GetHhwPath()` probe #1; a failed probe writes
   nothing). Seeding a fake path therefore makes the installer skip the
   "Additional components" page entirely and never extract or run
   `VC_HTML_Help_Workshop.msi`.

### Silent install that also skips HTML Help Workshop

    cd wine-fork-build
    export WINEPREFIX=$HOME/drex-fork-pref
    export DISPLAY=${DISPLAY:-:0}

    # 1. seed the fake HHW path (any directory containing hhc.exe)
    mkdir -p "$WINEPREFIX/drive_c/fake_hhw"
    : > "$WINEPREFIX/drive_c/fake_hhw/hhc.exe"
    ./wine reg add 'HKCU\Software\Indigo Byte Systems\Dr.Explain\CHMExport' \
        /v 'MSHHW Path' /t REG_SZ /d 'C:\fake_hhw' /f

    # 2. silent install
    WINEDLLOVERRIDES="mscoree,mshtml=" \
        ./wine /tmp/drexplain-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART

    # 3. optional cleanup of the seed
    rm -rf "$WINEPREFIX/drive_c/fake_hhw"
    ./wine reg delete 'HKCU\Software\Indigo Byte Systems\Dr.Explain\CHMExport' \
        /v 'MSHHW Path' /f

Verified under this build (exit 0, `DrExplain.exe` installed, no
`C:\Program Files (x86)\HTML Help Workshop` before or after the install,
`MSHHW Path` value unchanged, and **zero**
`Extracting temporary file: ...VC_HTML_Help_Workshop.msi` lines in the Inno
log â€” add `/LOG=z:\tmp\silent-inno.log` to check this yourself; the file
lands in the Linux `/tmp`, not inside the prefix).

## 8. First start of Dr.Explain

After the installer launches the app (or run it manually):

    WINEPREFIX=$HOME/drex-fork-pref WINEDLLOVERRIDES="mscoree,mshtml=" \
        ./wine "$HOME/drex-fork-pref/drive_c/Program Files/DrExplain/DrExplain.exe"

- On the license nag click **"Continue using a free restricted license"**.
- `Help â†’ About Dr.Explain...` should show **Version: 7.2.1394**.

## 9. Verifying the caret fixes by hand

In any text field of Dr.Explain (e.g. Settings â†’ activation dialog â†’
"Order ID", type `test` first):

- click in the middle of the word â†’ the caret lands between the two letters
  ("te|st"), not at start-of-text (bug 59488);
- click well past the end of the (short) text, still inside the field â†’ the
  caret reliably lands at the end of the text (bug 59488, real trailing-slot
  hypothesis path);
- drag-select the text by mouse â†’ no hang, no caret oscillating at input start
  (bug 59489, previously the app passed the FAILed hypothesis range to
  HitTestTextRange).

A dwrite trace confirms both code paths are live with the new build:

    WINEDEBUG=+dwrite WINEPREFIX=$HOME/drex-fork-pref \
        ./wine "$HOME/drex-fork-pref/drive_c/Program Files/DrExplain/DrExplain.exe"

then in the log:

- `trace:dwrite:dwritetextlayout_HitTestPoint` calls appear for every click
  (including clicks with coordinates past the text: the caret still moves,
  the function maps them to the real trailing box, no FIXME fallback);
- `trace:dwrite:dwritetextlayout_HitTestTextRange` calls appear during
  drag-selection and do not crash the app;
- the remaining `fixme:dwrite:dwritefactory_CreateMonitorRenderingParams`
  message is an unrelated cosmetic stub and stays at one line.

## 10. Files and versions used on the verification box

- Ubuntu 26.04 LTS, gcc 15.2.0-5ubuntu1, make 4.4.1-3, bison 3.8.2, flex 2.6.4,
  git 2.53.0, gcc-mingw-w64 13.2.0 (C only, no g++-mingw-w64).
- Dr.Explain 7.2 build 1394 (15-Sep-2026), downloaded from
  <https://www.drexplain.com/download/>.
