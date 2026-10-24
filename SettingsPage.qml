import QtQuick
import qs.Commons
import qs.Ui

// Server/token setup. Edits are STAGED in this page's draft* properties and
// only reach panel.server / panel.token / panel.backend through
// panel.saveConfig(draft...) on Connect. They used to write the panel live on
// every keystroke, so a half-typed token drove real requests, and toggling the
// backend mid-film unloaded the player under a session nothing could stop.
// The write itself goes through the stdin-fed, cwd-pinned, atomic-rename
// Process in the root.
Item {
  id: page

  required property var panel

  // Rows the keyboard cursor can land on, top to bottom. The backend row is
  // the only one where a horizontal move means anything.
  readonly property int rowServer: 0
  readonly property int rowToken: 1
  readonly property int rowBackend: 2
  readonly property int rowConnect: 3
  readonly property int rowRefresh: 4
  property int cursorRow: 0

  // Drafts start as BINDINGS to the panel, so a config that lands while the
  // setup page is already up (configRead finishing after open()) still fills
  // the form. The first edit breaks the binding, and from then on the draft
  // is the user's.
  property string draftServer: page.panel.server
  property string draftToken: page.panel.token
  property string draftBackend: page.panel.backend

  // The Refresh row only exists once there is a server to refresh; on first
  // run Down from Connect used to land on the hidden button.
  readonly property int lastRow: page.panel.configured() ? page.rowRefresh : page.rowConnect

  function toggleBackend() {
    page.draftBackend = page.draftBackend === "mpv" ? "internal" : "mpv"
  }

  // Claims the shared cursor for a row without moving focus — what hovering
  // does. The kit TextField and Button paint their own hover, so a control
  // that did not claim the cursor on hover showed a second highlight next to
  // the keyboard's.
  function claim(row) {
    page.cursorRow = row
    page.panel.setPanelCursor("page", "")
  }

  // The page cursor is only "the" cursor while the panel cursor is in the
  // page region — otherwise the sidebar/search highlight would coexist
  // with ours and break the single-highlight rule.
  readonly property bool cursorHere: panel.cursorRegion === "page"

  function moveCursor(dx, dy) {
    if (dx !== 0 && page.cursorRow === page.rowBackend) {
      page.toggleBackend()
      return
    }
    if (dy === 0) return
    page.cursorRow = Math.max(0, Math.min(page.lastRow, page.cursorRow + dy))
    page.syncFocus()
  }

  // Landing on a text row puts the caret there; every other row hands focus
  // BACK to the panel's key host. Without the release, the caret stayed in
  // the token field while the cursor sat on the backend row, so the h/l that
  // row's tooltip advertises typed into the masked token instead (verified:
  // "abcDEF123" became "abcDEF123l").
  function syncFocus() {
    if (page.cursorRow === page.rowServer) serverField.forceActiveFocus()
    else if (page.cursorRow === page.rowToken) tokenField.forceActiveFocus()
    else if (serverField.activeFocus || tokenField.activeFocus) page.panel.focusKeyHost()
  }

  function activateCursor() {
    if (page.cursorRow === page.rowServer) serverField.forceActiveFocus()
    else if (page.cursorRow === page.rowToken) tokenField.forceActiveFocus()
    else if (page.cursorRow === page.rowBackend) page.toggleBackend()
    else if (page.cursorRow === page.rowRefresh) page.panel.refresh()
    else page.commit()
  }

  function pageUp() { page.moveCursor(0, -1) }
  function pageDown() { page.moveCursor(0, 1) }

  // Normalising the trailing slash here keeps Model.validServer's origin-only
  // rule from rejecting an otherwise fine paste.
  function commit() {
    page.draftServer = String(page.draftServer).trim().replace(/\/+$/, "")
    page.draftToken = String(page.draftToken).trim()
    if (page.panel.saveConfig(page.draftServer, page.draftToken, page.draftBackend))
      page.panel.configApplied()
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
      // QQC2 TextField consumes Tab for its own focus chain — forward it so
      // region cycling survives a caret in this field.
      Keys.onTabPressed: function(event) { event.accepted = true; panel.cycleRegion(1) }
      Keys.onBacktabPressed: function(event) { event.accepted = true; panel.cycleRegion(-1) }
      width: parent.width
      hasCursor: page.cursorHere && page.cursorRow === page.rowServer
      placeholderText: "Server URL e.g. http://192.168.1.50:32400"
      // One-way seed from the draft, and the raw text goes back untrimmed:
      // writing a trimmed value would re-feed this binding and move the caret
      // mid-keystroke. commit() trims.
      text: page.draftServer
      onTextEdited: page.draftServer = text
      onAccepted: page.commit()
      onActiveFocusChanged: if (activeFocus) page.claim(page.rowServer)
      onHoveredChanged: if (hovered) page.claim(page.rowServer)
    }

    TextField {
      id: tokenField
      // QQC2 TextField consumes Tab for its own focus chain — forward it so
      // region cycling survives a caret in this field.
      Keys.onTabPressed: function(event) { event.accepted = true; panel.cycleRegion(1) }
      Keys.onBacktabPressed: function(event) { event.accepted = true; panel.cycleRegion(-1) }
      width: parent.width
      hasCursor: page.cursorHere && page.cursorRow === page.rowToken
      password: true
      placeholderText: "X-Plex-Token (app.plex.tv URL or plex.tv/api/devices)"
      text: page.draftToken
      onTextEdited: page.draftToken = text
      onAccepted: page.commit()
      onActiveFocusChanged: if (activeFocus) page.claim(page.rowToken)
      onHoveredChanged: if (hovered) page.claim(page.rowToken)
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
        selected: page.draftBackend !== "mpv"
        hasCursor: page.cursorHere && page.cursorRow === page.rowBackend && page.draftBackend !== "mpv"
        onClicked: { page.claim(page.rowBackend); page.syncFocus(); page.draftBackend = "internal" }
        onHovered: function(on) { if (on) page.claim(page.rowBackend) }
      }

      Button {
        text: "mpv"
        tooltipText: "Play in a standalone mpv window with hardware decode · h/l"
        bordered: true
        selected: page.draftBackend === "mpv"
        hasCursor: page.cursorHere && page.cursorRow === page.rowBackend && page.draftBackend === "mpv"
        onClicked: { page.claim(page.rowBackend); page.syncFocus(); page.draftBackend = "mpv" }
        onHovered: function(on) { if (on) page.claim(page.rowBackend) }
      }
    }

    // Which engine is actually rendering, and how to get the better one —
    // the closest a pure-QML plugin can get to bundling the native module.
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: (page.draftBackend === "mpv"
        ? "Video engine: external mpv window"
        : (page.panel.nativeReady
          ? "Video engine: native libmpv — hardware decode, HDR tone mapping"
          : "Video engine: QtMultimedia. For hardware decode + HDR, build the native module: ./native/install.sh, then restart the shell."))
        + (page.draftBackend !== page.panel.backend ? " Applies when you press Connect." : "")
    }

    Item { width: 1; height: Style.space(4) }

    Button {
      id: connectButton
      text: "Connect"
      tooltipText: "Save and load your library · Enter"
      bordered: true
      hasCursor: page.cursorHere && page.cursorRow === page.rowConnect
      onClicked: page.commit()
      onHovered: function(on) { if (on) page.claim(page.rowConnect) }
    }

    Button {
      text: "Refresh library"
      // Refreshing is rare enough that it reads as clutter in the browse
      // header, so it lives here. R still works.
      tooltipText: "Re-read libraries and the current page · R"
      bordered: true
      focusable: false
      visible: page.panel.configured()
      hasCursor: page.cursorHere && page.cursorRow === page.rowRefresh
      onClicked: page.panel.refresh()
      onHovered: function(on) { if (on) page.claim(page.rowRefresh) }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      // Artwork goes through QML Image, which cannot send headers, so poster
      // URLs carry the token as a query parameter (DESIGN.md "Known risks").
      // The old line promised headers only, which was never true.
      text: "Nothing changes until Connect. The token is saved chmod 600 in "
        + "~/.config/omarchy-plex/config.json and is only sent to your Plex server."
    }
  }
}
