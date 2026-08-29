# PlexMpv — native libmpv video item

A compiled QML module exposing one type, `MpvVideo`, that renders video with
libmpv inside the Quickshell process. The panel imports it when present and
falls back to QtMultimedia when it is not.

## Why

QtMultimedia's video sink does no HDR tone mapping, so a 4K DoVi/HDR10 library
plays with crushed blacks and clipped highlights, and on NVIDIA it often drops to
software decode. libmpv handles both. This module wraps
[MpvQt](https://invent.kde.org/libraries/mpvqt) (KDE's libmpv QtQuick binding,
the foundation under Haruna) rather than libmpv directly, because MpvQt already
owns the hard parts: the `mpv_render_context` lifecycle on the Qt render thread
and the mpv event loop off the GUI thread.

## Requirements

- Qt 6.5+ (built and tested against 6.11)
- `mpvqt` (Arch: `extra/mpvqt`), which pulls in `libmpv`
- CMake 3.21+, a C++20 compiler

**Hard constraint:** `MpvQt::MpvAbstractItem` derives from
`QQuickFramebufferObject`, which Qt documents as "only functional when Qt Quick
is rendering via OpenGL. It is not compatible with other graphics APIs, such as
Vulkan or Metal." Qt Quick defaults to the OpenGL RHI backend on Linux, and
Quickshell does not override it, so this works out of the box. But if
`QSG_RHI_BACKEND=vulkan` is ever set for the shell, this module stops rendering.
See `docs/` and the integration notes for the fallback contract.

## Build

```sh
cmake -B build && cmake --build build
```

Output lands in `build/qml/PlexMpv/` (`libplexmpv.so`, `qmldir`,
`plexmpv.qmltypes`) — a directory laid out exactly like the deployed one.

## Install

System-wide, onto the QML engine's default import path (needs root):

```sh
sudo cmake --install build
```

That writes to `/usr/lib/qt6/qml/PlexMpv/`. No environment variable is needed
afterwards; the engine finds it on its own.

For a dev install without root, pick any directory and put it on the import path:

```sh
cmake -B build -DQML_INSTALL_DIR="$HOME/.local/lib/qml"
cmake --build build && cmake --install build
QML2_IMPORT_PATH="$HOME/.local/lib/qml" quickshell -n -p /usr/share/omarchy/shell
```

Or skip installing entirely and point the shell straight at the build tree,
which is laid out identically:

```sh
QML2_IMPORT_PATH="$PWD/build/qml" quickshell -n -p /usr/share/omarchy/shell
```

Quickshell inherits Qt's standard import-path handling (it calls
`QQmlEngine::addImportPath` for its own paths but never clears the defaults), so
`QML2_IMPORT_PATH` is honoured.

## API

```qml
import PlexMpv 1.0

MpvVideo {
    httpHeaders: ["X-Plex-Token: " + token]   // set BEFORE loadUrl

    // properties: paused (rw), timePos (r), duration (r),
    //             volume (rw, 0-200), muted (rw)
    // methods:    loadUrl(url, startSeconds), stop(),
    //             seekAbsolute(s), seekRelative(s),
    //             setAudioTrack(n), setSubtitleTrack(n)   // 1-based, <1 = none
    // signals:    fileLoaded(), endReached(), playbackFailed(reason)
}
```

`httpHeaders` is the security improvement over the external-mpv backend: that one
passes the Plex token in argv, where it is readable from `/proc/PID/cmdline`.
Here it never leaves the process.
