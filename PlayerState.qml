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
// Nothing here is Plex-specific on purpose: the contract is three properties.
Item {
  id: root

  // Never actually shown; a service entry point is pure state, not UI.
  visible: false
  width: 0
  height: 0

  // The shell fills these in for every service instance that declares them
  // (shell.qml:305-309).
  property var shell: null
  property var manifest: null

  // Published by PlexPanel.qml's state handlers; read by BarWidget.qml.
  property bool playing: false
  property bool paused: false
  property string title: ""
}
