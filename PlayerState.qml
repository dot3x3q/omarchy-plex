import QtQuick

// Shared now-playing state: the plugin's "service" entry point.
//
// The shell loads exactly one instance of this per session (shell.qml's
// ensureService(), cached in shell._services{}) and hands the SAME instance
// to both other entry points of this plugin:
//   - the panel gets it as `item.service` because the panel loader does
//     `if ("service" in item) item.service = shell.serviceFor(pluginId)`
//     (/usr/share/omarchy/shell/shell.qml:637) whenever PlexPanel.qml
//     declares a `property var service: null`.
//   - the bar widget reaches it via `bar.shell.serviceFor(moduleName)`,
//     because the bar hands every widget instance `bar: <Bar instance>`
//     (/usr/share/omarchy/shell/plugins/bar/Bar.qml:1753) and the Bar
//     instance carries `.shell` (Bar.qml:25) — exactly how
//     quickshell.spotify's BarWidget.qml:16 reaches its own Service.qml.
//
// This is the plugin-author-facing contract; nothing here is Plex-specific
// on purpose so the panel rewrite only has to set three properties.
Item {
  id: root

  // Never actually shown; a service entry point is pure state, not UI.
  visible: false
  width: 0
  height: 0

  // Standard properties the shell fills in for every service instance if
  // present (see shell.qml:305-309). Unused today but declared so a future
  // need (reading manifest metadata, calling back into the shell) doesn't
  // require touching the panel-side wiring again.
  property var shell: null
  property var manifest: null

  // Published by PlexPanel.qml's existing state handlers; read by
  // BarWidget.qml. Kept intentionally tiny — exactly the
  // {playing, title, paused} shape the bar widget needs and nothing else.
  property bool playing: false
  property bool paused: false
  property string title: ""
}
