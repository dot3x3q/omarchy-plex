import QtQuick
import qs.Commons
import qs.Ui

// Server/token setup, restyled onto the shared kit. The IO underneath is
// untouched: this page only edits panel.server / panel.token / panel.backend
// and calls panel.saveConfig(), which still writes through the stdin-fed,
// cwd-pinned, atomic-rename Process in the root.
Item {
  id: page

  required property var panel

  // Rows the keyboard cursor can land on, top to bottom. The backend row is
  // the only one where a horizontal move means anything.
  readonly property int rowServer: 0
  readonly property int rowToken: 1
  readonly property int rowBackend: 2
  readonly property int rowConnect: 3
  property int cursorRow: 0

  // The page cursor is only "the" cursor while the panel cursor is in the
  // page region — otherwise the sidebar/search highlight would coexist
  // with ours and break the single-highlight rule.
  readonly property bool cursorHere: panel.cursorRegion === "page"

  function moveCursor(dx, dy) {
    if (dx !== 0 && page.cursorRow === page.rowBackend) {
      page.panel.backend = page.panel.backend === "mpv" ? "internal" : "mpv"
      return
    }
    if (dy === 0) return
    page.cursorRow = Math.max(0, Math.min(page.rowConnect, page.cursorRow + dy))
    // Landing on a text row should put the caret there; the other rows are
    // activated with Enter instead.
    if (page.cursorRow === page.rowServer) serverField.forceActiveFocus()
    else if (page.cursorRow === page.rowToken) tokenField.forceActiveFocus()
  }

  function activateCursor() {
    if (page.cursorRow === page.rowServer) serverField.forceActiveFocus()
    else if (page.cursorRow === page.rowToken) tokenField.forceActiveFocus()
    else if (page.cursorRow === page.rowBackend) page.panel.backend = page.panel.backend === "mpv" ? "internal" : "mpv"
    else page.commit()
  }

  function pageUp() { page.moveCursor(0, -1) }
  function pageDown() { page.moveCursor(0, 1) }

  // Normalising the trailing slash here keeps Model.validServer's origin-only
  // rule from rejecting an otherwise fine paste.
  function commit() {
    page.panel.server = String(page.panel.server).trim().replace(/\/+$/, "")
    if (page.panel.saveConfig()) page.panel.configApplied()
  }

  Column {
    id: form
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(10)

    Text {
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
      text: "PLEX SERVER"
    }

    TextField {
      id: serverField
      // QQC2 TextField consumes Tab for its own focus chain (the same bug
      // the search field was field-tested into fixing) — forward it so
      // region cycling survives a caret in this field.
      Keys.onTabPressed: function(event) { event.accepted = true; panel.cycleRegion(1) }
      Keys.onBacktabPressed: function(event) { event.accepted = true; panel.cycleRegion(-1) }
      width: parent.width
      hasCursor: page.cursorHere && page.cursorRow === page.rowServer
      placeholderText: "Server URL e.g. http://192.168.1.50:32400"
      // One-way seed only: binding this both ways caused a loop that corrupted
      // typed URLs mid-keystroke.
      text: page.panel.server
      onTextEdited: page.panel.server = text.trim()
      onAccepted: page.commit()
      onActiveFocusChanged: if (activeFocus) page.cursorRow = page.rowServer
    }

    TextField {
      id: tokenField
      // QQC2 TextField consumes Tab for its own focus chain (the same bug
      // the search field was field-tested into fixing) — forward it so
      // region cycling survives a caret in this field.
      Keys.onTabPressed: function(event) { event.accepted = true; panel.cycleRegion(1) }
      Keys.onBacktabPressed: function(event) { event.accepted = true; panel.cycleRegion(-1) }
      width: parent.width
      hasCursor: page.cursorHere && page.cursorRow === page.rowToken
      password: true
      placeholderText: "X-Plex-Token (app.plex.tv URL or plex.tv/api/devices)"
      text: page.panel.token
      onTextEdited: page.panel.token = text.trim()
      onAccepted: page.commit()
      onActiveFocusChanged: if (activeFocus) page.cursorRow = page.rowToken
    }

    Text {
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
      text: "PLAYBACK BACKEND"
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: "In panel"
        tooltipText: "Render video inside this window (QtMultimedia) · h/l"
        bordered: true
        selected: page.panel.backend !== "mpv"
        hasCursor: page.cursorHere && page.cursorRow === page.rowBackend && page.panel.backend !== "mpv"
        onClicked: { page.cursorRow = page.rowBackend; page.panel.backend = "internal" }
        onHovered: function(on) { if (on) { page.cursorRow = page.rowBackend; page.panel.setPanelCursor("page", "") } }
      }

      Button {
        text: "mpv"
        tooltipText: "Play in a standalone mpv window with hardware decode · h/l"
        bordered: true
        selected: page.panel.backend === "mpv"
        hasCursor: page.cursorHere && page.cursorRow === page.rowBackend && page.panel.backend === "mpv"
        onClicked: { page.cursorRow = page.rowBackend; page.panel.backend = "mpv" }
        onHovered: function(on) { if (on) { page.cursorRow = page.rowBackend; page.panel.setPanelCursor("page", "") } }
      }
    }

    Item { width: 1; height: Style.space(4) }

    Button {
      id: connectButton
      text: "Connect"
      tooltipText: "Save and load your library · Enter"
      bordered: true
      hasCursor: page.cursorHere && page.cursorRow === page.rowConnect
      onClicked: page.commit()
      onHovered: function(on) { if (on) { page.cursorRow = page.rowConnect; page.panel.setPanelCursor("page", "") } }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: "Enter saves. The token is written chmod 600 to ~/.config/plexmini/config.json "
        + "and only ever travels in request headers."
    }
  }
}
