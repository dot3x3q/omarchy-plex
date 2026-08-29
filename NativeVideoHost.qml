import QtQuick
import PlexMpv 1.0

// The native libmpv video surface — and the probe for whether it exists.
//
// This file is loaded by a Loader in PlexPanel.qml rather than instantiated
// directly, and that indirection is the entire point: `import PlexMpv 1.0` is
// resolved when THIS file is loaded, not when the panel is. If the compiled
// module is missing (never built, uninstalled, a Qt upgrade that broke the
// plugin ABI), the Loader goes to Loader.Error and the panel carries on with
// QtMultimedia. Importing PlexMpv in PlexPanel.qml instead would take the whole
// plugin down with it.
//
// That fallback tier is PERMANENT, not scaffolding. MpvQt's MpvAbstractItem
// derives from QQuickFramebufferObject, which Qt documents as OpenGL-only — set
// QSG_RHI_BACKEND=vulkan for the shell and this renders nothing at all while
// still loading successfully. QtMultimedia has to stay reachable. See
// native/README.md and native/mpvvideo.h.
//
// Linting note: this file reports warnings, not errors, and they are expected.
// MpvQt is a plain C++ library and ships no .qmltypes, so the linter cannot
// resolve MpvAbstractItem and therefore cannot see the QQuickItem members
// (anchors, parent) that MpvVideo inherits through it. The type is real at
// runtime — qmlcachegen compiles this file cleanly against the installed
// module — and only the static description of its base class is missing.
MpvVideo {
  anchors.fill: parent
}
