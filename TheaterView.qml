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
// Overlay strip anatomy follows the Spotify plugin's footer (MIT): a seek
// slider between position and duration captions, a transport cluster, and the
// title. Cursor region is "playing" for every control on it.
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
  MouseArea {
    id: videoSurface
    anchors.fill: parent
    hoverEnabled: true
    onPositionChanged: view.panel.pokeTheaterControls()
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
    height: Style.space(84)
    radius: Style.cornerRadius
    color: Style.normalFillFor(view.foreground, view.accent)
    borderSpec: Border.controlSpec("normal", view.foreground, view.accent)

    // Hovering the strip holds it open even with the pointer perfectly still —
    // the timeout is there to get the chrome out of the way of the film, not to
    // yank a button out from under the cursor.
    opacity: view.panel.theaterControlsVisible || stripHover.hovered ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 120 } }

    HoverHandler { id: stripHover }

    Text {
      id: positionCaption
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      color: view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: Model.fmtDuration(view.panel.seekDisplayTime)
    }

    Text {
      id: durationCaption
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.top: positionCaption.top
      color: view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: Model.fmtDuration(view.panel.dispDuration)
    }

    CursorSurface {
      id: seekCursor
      anchors.left: positionCaption.right
      anchors.leftMargin: Style.space(8)
      anchors.right: durationCaption.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: positionCaption.verticalCenter
      height: seekSlider.implicitHeight
      hasCursor: view.panel.cursorOn("playing", "seek")
      foreground: view.foreground
      accent: view.accent

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
        onMoved: function(seconds) { view.panel.previewSeek(seconds) }
        onReleased: function(seconds) { view.panel.commitSeek(seconds) }

        HoverHandler { id: seekSliderHover }
        PanelToolTip {
          visible: seekSliderHover.hovered
          text: "Seek 10s · ← / → · Shift for 30s"
        }
      }
    }

    Text {
      id: theaterTitle
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: transportRow.left
      anchors.rightMargin: Style.space(10)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(14)
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: view.panel.currentTitle
    }

    Row {
      id: transportRow
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(6)
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
  }
}
