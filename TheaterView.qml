import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Theater overlay: the auto-hiding control strip that floats over the video.
//
// The VideoOutput itself is NOT here. It lives in PlexPanel.qml as a permanent
// full-bleed layer, because QtMultimedia holds it as the player's sink for the
// life of the session and this file is behind a Loader that unloads every time
// you drop to browse. What is here is everything that should vanish when you
// stop touching the machine.
//
// Overlay strip anatomy follows the Spotify plugin's footer (MIT), squeezed
// into ONE row: title, position, seek, duration, transport, volume. The two-row
// version was 84px of chrome over the film for the same six things.
// Cursor region is "playing" for every control on it.
Item {
  id: view

  required property var panel

  readonly property color foreground: Color.foreground
  readonly property color muted: Color.muted
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family

  // Pointer movement anywhere over the video wakes the strip. Sits below the
  // strip so its buttons keep their own clicks; the strip has its own hover
  // handler for the case where the pointer is parked on a control.
  //
  // It is also the theater half of drag-anywhere: the window has no chrome to
  // grab, and a full-bleed video is the largest bare surface in the app. Past
  // the threshold the compositor takes the gesture over; below it, a click is
  // still just a click that pokes the controls awake.
  MouseArea {
    id: videoSurface
    anchors.fill: parent
    hoverEnabled: true

    property real pressX: 0
    property real pressY: 0
    property bool handedOff: false

    onPressed: function(mouse) {
      videoSurface.pressX = mouse.x
      videoSurface.pressY = mouse.y
      videoSurface.handedOff = false
    }
    onPositionChanged: function(mouse) {
      view.panel.pokeTheaterControls()
      if (!videoSurface.pressed || videoSurface.handedOff) return
      if (Math.abs(mouse.x - videoSurface.pressX) < view.panel.dragThreshold
          && Math.abs(mouse.y - videoSurface.pressY) < view.panel.dragThreshold) return
      videoSurface.handedOff = true
      view.panel.beginWindowDrag()
    }
    onClicked: view.panel.pokeTheaterControls()
  }

  // mpv renders into its own window, so in that backend the theater is a plate
  // that says where the picture went. The strip below still works — it drives
  // mpv over IPC exactly as it drives the internal player.
  Text {
    anchors.centerIn: parent
    visible: view.panel.backend === "mpv"
    color: view.muted
    font.family: view.fontFamily
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    text: view.panel.triedTranscode
      ? "Playing via server transcode — mpv has the picture"
      : "Playing in mpv (hardware decode)"
  }

  BorderSurface {
    id: strip
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(14)
    height: Style.space(46)
    radius: Style.cornerRadius
    color: Style.normalFillFor(view.foreground, view.accent)
    borderSpec: Border.controlSpec("normal", view.foreground, view.accent)

    // One row has to give something up in a narrow window. The title goes
    // first — the window is already titled and the picture is right there — and
    // the volume slider second, since ↑/↓ and the mute button still cover it.
    readonly property bool showTitle: strip.width > Style.space(700)
    readonly property bool showVolume: !view.panel.mpvMode && strip.width > Style.space(520)

    // Hovering the strip holds it open even with the pointer perfectly still —
    // the timeout is there to get the chrome out of the way of the film, not to
    // yank a button out from under the cursor.
    opacity: view.panel.theaterControlsVisible || stripHover.hovered ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 120 } }

    HoverHandler { id: stripHover }

    Text {
      id: theaterTitle
      visible: strip.showTitle
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      // Never more than a third of the strip: the seek slider is the control
      // that actually needs the width, and a long episode title would eat it.
      width: visible ? Math.min(implicitWidth, Math.max(0, strip.width * 0.3)) : 0
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: view.panel.currentTitle
    }

    Text {
      id: positionCaption
      anchors.left: strip.showTitle ? theaterTitle.right : parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      color: view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: Model.fmtDuration(view.panel.seekDisplayTime)
    }

    // ---------- right-hand cluster, anchored right to left ----------

    CursorSurface {
      id: volumeCursor
      visible: strip.showVolume
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.space(84) : 0
      height: volumeSlider.implicitHeight
      hasCursor: view.panel.cursorOn("playing", "volume")
      foreground: view.foreground
      accent: view.accent
      // Same no-box treatment as the scrubbers: two adjacent sliders where only
      // one grew a rectangle on hover would read as a bug.
      fill: "transparent"
      borderSpec: Border.none()

      HoverHandler {
        id: volumeHover
        onHoveredChanged: if (hovered) view.panel.setPanelCursor("playing", "volume")
      }

      PanelSlider {
        id: volumeSlider
        anchors.fill: parent
        bar: view.panel.panelBar
        minimum: 0
        maximum: 200
        step: 5
        integer: true
        // Five evenly-spaced notches over 0–200 land on 0/50/100/150/200, so
        // one of them sits exactly on 100 — the line where Qt's own ceiling
        // stops and the PipeWire boost starts. That is the mark that matters.
        tickCount: 5
        value: view.panel.volumePct
        knobColor: view.panel.cursorOn("playing", "volume") ? view.accent : view.foreground
        onMoved: function(pct) { view.panel.setVolumePct(pct) }
        onReleased: function(pct) { view.panel.setVolumePct(pct) }

        PanelToolTip {
          visible: volumeHover.hovered
          text: "Volume · ↑ / ↓ · boosts to 200%"
        }
      }
    }

    // Fixed-width slot whose TEXT comes and goes, so the row never reflows when
    // the reading appears. Shows for any adjustment, keyboard included.
    Text {
      id: volumeCaption
      visible: strip.showVolume
      anchors.right: volumeCursor.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Style.space(34) : 0
      horizontalAlignment: Text.AlignRight
      color: view.panel.volumePct > 100 ? view.accent : view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: (view.panel.volumeAdjusting || volumeHover.hovered || volumeSlider.dragging)
        ? view.panel.volumePct + "%" : ""
    }

    Row {
      id: transportRow
      anchors.right: strip.showVolume ? volumeCaption.left : parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      TransportButton {
        glyphText: "󰒮"
        tooltipText: "Back 10s · ←"
        foreground: view.foreground
        hasCursor: view.panel.cursorOn("playing", "rewind")
        onClicked: view.panel.nudgeSeek(-10)
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "rewind")
        }
      }

      TransportButton {
        glyphText: view.panel.isPaused ? "󰐊" : "󰏤"
        glyphSize: Style.font.iconLarge
        tooltipText: view.panel.isPaused ? "Play · Space" : "Pause · Space"
        foreground: view.foreground
        hasCursor: view.panel.cursorOn("playing", "play")
        onClicked: view.panel.togglePause()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "play")
        }
      }

      TransportButton {
        glyphText: "󰒭"
        tooltipText: "Forward 10s · →"
        foreground: view.foreground
        hasCursor: view.panel.cursorOn("playing", "forward")
        onClicked: view.panel.nudgeSeek(10)
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "forward")
        }
      }

      // Volume lives in the internal player's AudioOutput; mpv owns its own.
      TransportButton {
        visible: !view.panel.mpvMode
        glyphText: view.panel.audioMuted ? "󰖁" : "󰕾"
        tooltipText: view.panel.audioMuted ? "Unmute · M" : "Mute · M"
        foreground: view.panel.audioMuted ? view.urgent : view.foreground
        hasCursor: view.panel.cursorOn("playing", "mute")
        onClicked: view.panel.toggleMute()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "mute")
        }
      }

      // Track pickers. Both are absent rather than disabled when the item has
      // nothing to pick between — a dead button on a nine-button strip is just
      // noise, and the tooltip has nothing useful to say about "this film has
      // one audio track".
      TransportButton {
        id: audioTrackButton
        visible: view.panel.audioPickerAvailable
        width: visible ? controlSize : 0
        glyphText: "\u{f05c5}"
        tooltipText: "Audio track · A"
        foreground: view.foreground
        selected: view.panel.trackPopup === "audio"
        hasCursor: view.panel.cursorOn("playing", "audiotrack")
        onClicked: view.panel.toggleTrackPopup("audio")
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "audiotrack")
        }
      }

      TransportButton {
        id: subtitleTrackButton
        visible: view.panel.subtitlePickerAvailable
        width: visible ? controlSize : 0
        glyphText: "\u{f0a16}"
        tooltipText: "Subtitles · S"
        foreground: view.foreground
        selected: view.panel.trackPopup === "subtitle"
        hasCursor: view.panel.cursorOn("playing", "subtitletrack")
        onClicked: view.panel.toggleTrackPopup("subtitle")
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "subtitletrack")
        }
      }

      TransportButton {
        glyphText: "󰓛"
        tooltipText: "Stop"
        foreground: view.urgent
        hasCursor: view.panel.cursorOn("playing", "stop")
        onClicked: view.panel.stop()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "stop")
        }
      }

      // Theater hides the header, so this is the only reachable way into the
      // PiP from the state where you most want it: watching, and wanting the
      // picture out of the tiling tree without stopping it.
      TransportButton {
        glyphText: "\u{f0403}"
        tooltipText: "Picture-in-picture · P"
        foreground: view.foreground
        hasCursor: view.panel.cursorOn("playing", "pip")
        onClicked: view.panel.toggleSurface()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "pip")
        }
      }

      TransportButton {
        glyphText: "󰅀"
        tooltipText: "Browse · Esc"
        foreground: view.foreground
        hasCursor: view.panel.cursorOn("playing", "browse")
        onClicked: view.panel.exitTheater()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "browse")
        }
      }
    }

    Text {
      id: durationCaption
      anchors.right: transportRow.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      color: view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: Model.fmtDuration(view.panel.dispDuration)
    }

    // The flexible middle: whatever the two captions and the two clusters leave.
    CursorSurface {
      id: seekCursor
      anchors.left: positionCaption.right
      anchors.leftMargin: Style.space(8)
      anchors.right: durationCaption.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: seekSlider.implicitHeight
      hasCursor: view.panel.cursorOn("playing", "seek")
      foreground: view.foreground
      accent: view.accent
      // No hover box on the timeline. The panel-cursor plumbing is untouched —
      // hover still claims the cursor and the keyboard "seek" action is still
      // reachable — but the fill and border are dropped, because a rectangle
      // snapping up around the scrubber reads as a rendering defect rather than
      // a highlight. The knob carries the keyboard indication instead.
      fill: "transparent"
      borderSpec: Border.none()

      HoverHandler {
        onHoveredChanged: if (hovered) view.panel.setPanelCursor("playing", "seek")
      }

      PanelSlider {
        id: seekSlider
        anchors.fill: parent
        bar: view.panel.panelBar
        minimum: 0
        maximum: Math.max(1, view.panel.dispDuration)
        step: 10
        // The previewed position, not the reported one: see the seek-ack block
        // in PlexPanel.qml for why the knob has to hold its ground.
        value: view.panel.seekDisplayTime
        // PanelSlider's own hot state is mouse-only and read-only, so the panel
        // cursor speaks through the knob's color instead of a surrounding box.
        knobColor: view.panel.cursorOn("playing", "seek") ? view.accent : view.foreground
        onMoved: function(seconds) { view.panel.previewSeek(seconds) }
        onReleased: function(seconds) { view.panel.commitSeek(seconds) }

        HoverHandler { id: seekSliderHover }
        PanelToolTip {
          visible: seekSliderHover.hovered
          text: "Seek 10s · ← / → · Shift for 30s"
        }
      }
    }
  }

  // ---------- track picker ----------
  // Declared after the strip so it paints above it, and click-away first so
  // the list itself keeps its own clicks. Deliberately NOT a QQC2 Popup: it
  // wants no focus scope and no Shortcut objects, because the panel's existing
  // key dispatcher already gives it first refusal (see handleTrackPopupKey) —
  // one keyboard model instead of two competing ones, and the layered-Esc
  // chain stays exactly as it was with the popup simply added at the front.
  MouseArea {
    id: pickerScrim
    anchors.fill: parent
    visible: view.panel.trackPopup !== ""
    // Bare click anywhere else dismisses, the same as Esc.
    onClicked: view.panel.closeTrackPopup()
  }

  BorderSurface {
    id: picker
    visible: view.panel.trackPopup !== ""
    readonly property var rows: visible ? view.panel.trackRows(view.panel.trackPopup) : []
    readonly property int rowHeight: Style.space(28)

    anchors.right: strip.right
    anchors.rightMargin: Style.space(6)
    anchors.bottom: strip.top
    anchors.bottomMargin: Style.space(6)
    width: Style.space(340)
    // Grows with the list up to a ceiling — a Crunchyroll episode can carry
    // twenty subtitle tracks, and the picker must not become the whole screen.
    height: Math.min(Style.space(300),
      picker.rows.length * picker.rowHeight + Style.space(16))
    radius: Style.cornerRadius
    color: Style.selectedFillFor(view.foreground, view.accent)
    borderSpec: Border.controlSpec("normal", view.foreground, view.accent)

    ListView {
      id: pickerList
      anchors.fill: parent
      anchors.margins: Style.space(8)
      clip: true
      model: picker.rows
      spacing: 0
      boundsBehavior: Flickable.StopAtBounds
      // Keep the keyboard cursor on screen when j walks past the fold.
      currentIndex: view.panel.trackPopupIndex
      highlightFollowsCurrentItem: true
      preferredHighlightBegin: 0
      preferredHighlightEnd: height
      highlightRangeMode: ListView.ApplyRange

      FastScrollHandler { flickable: pickerList }

      delegate: Button {
        required property var modelData
        required property int index

        width: pickerList.width
        height: picker.rowHeight
        leftAlign: true
        focusable: false
        foreground: view.foreground
        accent: view.accent
        // The panel cursor and the mouse share one highlight here exactly as
        // everywhere else — hovering a row moves the keyboard selection to it.
        hasCursor: view.panel.trackPopupIndex === index
        selected: modelData.current === true
        // Room on the right for the check and the hint, which are anchored
        // over the top of the label rather than laid out beside it.
        text: modelData.label
        rightPadding: Style.space(46)

        onClicked: view.panel.activateTrackRow(view.panel.trackPopup, modelData)
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.trackPopupIndex = index
        }

        // Why this row cannot just be flipped in the running pipeline: a
        // sidecar the player cannot see, or an image subtitle Qt cannot draw.
        // Both mean the server has to build a new stream, which costs a
        // restart — worth saying before the click, not after.
        Text {
          anchors.right: rowCheck.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: modelData.external === true
            ? "server"
            : (modelData.image === true && !view.panel.mpvMode ? "burn-in" : "")
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }

        Text {
          id: rowCheck
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          visible: modelData.current === true
          text: "\u{f012c}"
          color: view.accent
          font.family: view.fontFamily
          font.pixelSize: Style.font.icon
          textFormat: Text.PlainText
        }
      }
    }
  }
}
