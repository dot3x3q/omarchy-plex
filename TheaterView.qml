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
// into ONE row, deck order: title, transport (back · play · forward · stop),
// position, seek, duration, then volume and the pickers. The same deck-left-
// of-timeline order repeats on the PiP strip and the minibar — one layout to
// learn, three surfaces. Cursor region is "playing" for every control on it.
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
    // Scroll anywhere over the picture is volume, the same gesture as on the
    // PiP card. Deliberately no holdVolumePopup here: volumeAdjusting already
    // flashes the readout for 1500ms per step, exactly as a keyboard nudge
    // does, and a hold with no matching hover-out would pin the popup open.
    onWheel: function(wheel) {
      view.panel.pokeTheaterControls()
      view.panel.nudgeVolumeWheel(wheel.angleDelta.y > 0)
    }
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

    // One row has to give something up in a narrow window, and the title is
    // the only thing on it that can go: the volume slider is not in the row at
    // all — it hangs above the mute button on hover, costing no width.
    readonly property bool showTitle: strip.width > Style.space(700)

    // Hovering the strip holds it open even with the pointer perfectly still —
    // the timeout is there to get the chrome out of the way of the film, not to
    // yank a button out from under the cursor.
    opacity: view.panel.theaterControlsVisible || stripHover.hovered ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 120 } }

    HoverHandler { id: stripHover }

    // Collapsing widths on this strip key off their CONDITION, never off
    // `visible`: visibility is hierarchical, so while the strip is faded out
    // every child reads visible === false and a `visible ? w : 0` binding
    // silently reclaims its width for the scrubber. The track then snaps to
    // the narrower layout the instant the strip fades back in, and the
    // slider's 140ms knob Behavior glides the playhead left to catch up —
    // a visible false "seek" on every reveal.
    Text {
      id: theaterTitle
      visible: strip.showTitle
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      // Never more than a third of the strip: the seek slider is the control
      // that actually needs the width, and a long episode title would eat it.
      width: strip.showTitle ? Math.min(implicitWidth, Math.max(0, strip.width * 0.3)) : 0
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: view.panel.currentTitle
    }

    // ---------- deck cluster, left of the timeline ----------
    // Back · play · forward · stop, reading in deck order before the scrubber
    // the way every physical transport does.
    Row {
      id: deckRow
      anchors.left: theaterTitle.right
      anchors.leftMargin: strip.showTitle ? Style.space(10) : 0
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

      // Stop ends the session and Forward gets clicked in bursts; the wider
      // gap keeps a drifted triple-tap from landing on the one button in the
      // cluster there is no undo for.
      Item { width: Style.space(6); height: 1 }

      TransportButton {
        glyphText: "󰓛"
        tooltipText: "Stop · X"
        foreground: view.urgent
        hasCursor: view.panel.cursorOn("playing", "stop")
        onClicked: view.panel.stop()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "stop")
        }
      }
    }

    Text {
      id: positionCaption
      anchors.left: deckRow.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      color: view.muted
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      text: Model.fmtDuration(view.panel.seekDisplayTime)
    }

    // ---------- right-hand cluster: volume and the pickers ----------

    Row {
      id: transportRow
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      // Volume lives in the internal player's AudioOutput; mpv owns its own.
      // This button is also the volume popup's anchor: click mutes, hover
      // reveals the vertical slider above it, wheel adjusts without ever
      // needing the popup on screen first.
      TransportButton {
        id: muteButton
        visible: !view.panel.mpvMode
        glyphText: view.panel.audioMuted ? "󰖁" : "󰕾"
        tooltipText: view.panel.audioMuted
          ? "Unmute · M" : "Mute · M · scroll or hover for volume"
        foreground: view.panel.audioMuted ? view.urgent : view.foreground
        hasCursor: view.panel.cursorOn("playing", "mute")
        onClicked: view.panel.toggleMute()
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) {
            view.panel.setPanelCursor("playing", "mute")
            view.panel.holdVolumePopup()
          } else {
            view.panel.releaseVolumePopup()
          }
        }

        // A WheelHandler rather than a MouseArea: MouseArea has no wheel
        // handling at all, so wrapping the button in one eats the click and
        // still does not deliver the scroll.
        WheelHandler {
          onWheel: function(event) {
            view.panel.holdVolumePopup()
            view.panel.nudgeVolumeWheel(event.angleDelta.y > 0)
          }
        }

        // ---------- vertical volume popup ----------
        //
        // Declared as a CHILD of the button so it tracks it through every
        // reflow of a right-anchored Row for free — mapToItem arithmetic
        // against the strip would go stale the moment the window resized.
        // Nothing in the chain sets `clip`, and Qt Quick does not clip input
        // to parent bounds either, so a popup overhanging the strip still
        // hovers, drags and scrolls normally.
        //
        // Opaque body, unlike the translucent track picker. PanelSlider's
        // visual language assumes an opaque panel behind it — the knob's ring
        // is painted IN the background color to cut the knob out of the track —
        // and over moving video a translucent version of that reads as a
        // rendering fault. Same choice, and the same reason, as pipCard.
        BorderSurface {
          id: volumePopup
          anchors.bottom: parent.top
          anchors.bottomMargin: Style.space(8)
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(46)
          height: Style.space(160)
          radius: Style.cornerRadius
          color: view.panel.background
          borderSpec: Border.controlSpec("normal", view.foreground, view.accent)

          opacity: view.panel.volumePopupVisible ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 120 } }

          // Holding the popup open while the pointer is on IT, not just on the
          // button, is what makes the diagonal traverse survivable — together
          // with the grace period on the release side.
          HoverHandler {
            onHoveredChanged: {
              if (hovered) view.panel.holdVolumePopup()
              else view.panel.releaseVolumePopup()
            }
          }

          Text {
            id: volumeReadout
            anchors.top: parent.top
            anchors.topMargin: Style.space(7)
            anchors.horizontalCenter: parent.horizontalCenter
            text: view.panel.volumePct + "%"
            color: view.panel.volumePct > 100 ? view.accent : view.muted
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          // The vertical slider. PanelSlider is horizontal-only — its track
          // anchors left/right, its fill grows by width and its hit test reads
          // mouse.x — and rotating it would keep all three wrong: rotation
          // moves the painted output without moving the input geometry, so the
          // hit area and the tooltip would stay on the horizontal axis. So the
          // dimensions are transposed by hand and the ROLES are copied exactly:
          // track = selectedFill, fill = foreground, knob = a foreground circle
          // ringed in the panel background, ticks cut in the background color.
          Item {
            id: volumeVertical
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: volumeReadout.bottom
            anchors.topMargin: Style.space(8)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(12)
            width: Style.space(28)

            // Same formulas as PanelSlider, with height and width swapped.
            readonly property real trackThickness: Math.max(4,
              Math.round(Style.spacing.controlHeight * 0.11))
            readonly property real knobSize: Math.max(14,
              Math.round(Style.spacing.controlHeight * 0.38))
            property bool dragging: false

            // No separate liveValue. PanelSlider needs one because its knob has
            // to lead a value the caller may not have accepted yet; here every
            // drag frame writes a SNAPPED value straight through, and the knob
            // following that is exactly the magnetic feel we want — it visibly
            // sticks as it crosses a notch.
            readonly property real progress: Math.max(0, Math.min(1,
              view.panel.volumePct / 200))

            Rectangle {
              id: volumeTrack
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: volumeVertical.trackThickness
              radius: width / 2
              color: Style.selectedFillFor(view.foreground, view.accent)
            }

            Rectangle {
              id: volumeFill
              anchors.horizontalCenter: volumeTrack.horizontalCenter
              // Grows upward from the bottom: louder is higher.
              anchors.bottom: volumeTrack.bottom
              width: volumeTrack.width
              radius: volumeTrack.radius
              color: view.foreground
              height: volumeTrack.height * volumeVertical.progress

              Behavior on height {
                enabled: !volumeVertical.dragging
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
              }
            }

            // Five marks at 0/50/100/150/200 — index 0 is 0% and sits at the
            // BOTTOM, hence the 1 - fraction. Drawn in the panel background so
            // only the part crossing the track shows, exactly as PanelSlider
            // cuts its own notches.
            Repeater {
              model: 5
              Rectangle {
                required property int index
                width: volumeVertical.trackThickness + Style.space(4)
                height: Math.max(1, Style.space(2))
                radius: 1
                color: view.panel.background
                anchors.horizontalCenter: volumeTrack.horizontalCenter
                y: Math.max(0, Math.min(volumeTrack.height - height,
                  volumeTrack.height * (1 - index / 4) - height / 2))
              }
            }

            BorderSurface {
              id: volumeKnob
              width: volumeVertical.knobSize
              height: volumeVertical.knobSize
              radius: width / 2
              // The panel cursor speaks through the knob's color here for the
              // same reason it does on every other slider in this plugin.
              color: view.panel.cursorOn("playing", "mute") ? view.accent : view.foreground
              borderSpec: Border.flat(view.panel.background, Math.max(1, Style.space(2)))
              anchors.horizontalCenter: volumeTrack.horizontalCenter
              y: Math.max(0, Math.min(volumeTrack.height - height,
                volumeTrack.height * (1 - volumeVertical.progress) - height / 2))

              // No knob-grow on hover, unlike PanelSlider: this plugin's
              // animation budget is 140ms slider moves and 120ms popup fades,
              // and an unanimated scale pop reads worse than no scale at all.
              Behavior on y {
                enabled: !volumeVertical.dragging
                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
              }
            }

            MouseArea {
              id: volumeArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor

              // Inverted against the track, not the MouseArea: the track is
              // what the knob and fill are measured against, and the two must
              // not disagree about where 100% is.
              function valueFromY(y) {
                var span = Math.max(1, volumeTrack.height)
                var clamped = Math.max(0, Math.min(span, y - volumeTrack.y))
                return (1 - clamped / span) * 200
              }

              // Belt and braces over the popup's own HoverHandler. A MouseArea
              // with hoverEnabled can consume the hover the handler above was
              // relying on, and the failure mode is the popup closing under a
              // pointer that is sitting right on it. The `dragging` guard is
              // the important half: a drag legitimately leaves these 28px of
              // width, and the grab keeps feeding us positions after it does,
              // so leaving the bounds mid-gesture must NOT start the close.
              onContainsMouseChanged: {
                if (containsMouse) view.panel.holdVolumePopup()
                else if (!volumeVertical.dragging) view.panel.releaseVolumePopup()
              }

              onPressed: function(mouse) {
                volumeVertical.dragging = true
                view.panel.holdVolumePopup()
                view.panel.setVolumeSnapped(valueFromY(mouse.y))
              }
              onPositionChanged: function(mouse) {
                if (!volumeVertical.dragging) return
                view.panel.setVolumeSnapped(valueFromY(mouse.y))
              }
              // Releasing outside the slider is the one moment the guard above
              // deliberately skipped, so settle it here.
              onReleased: {
                volumeVertical.dragging = false
                if (!containsMouse) view.panel.releaseVolumePopup()
              }
              onWheel: function(wheel) {
                view.panel.holdVolumePopup()
                view.panel.nudgeVolumeWheel(wheel.angleDelta.y > 0)
              }

              PanelToolTip {
                visible: volumeArea.containsMouse && !volumeVertical.dragging
                text: "Volume · ↑ / ↓ · snaps at 50/100/150/200 · boosts to 200%"
              }
            }
          }
        }
      }

      // Track pickers. Both are absent rather than disabled when the item has
      // nothing to pick between — a dead button on a nine-button strip is just
      // noise, and the tooltip has nothing useful to say about "this film has
      // one audio track".
      TransportButton {
        id: audioTrackButton
        visible: view.panel.audioPickerAvailable
        // Condition, not `visible` — see the note above theaterTitle.
        width: view.panel.audioPickerAvailable ? controlSize : 0
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
        width: view.panel.subtitlePickerAvailable ? controlSize : 0
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

      // Stream quality. Unlike the two track buttons this is never absent while
      // a session is live: "Original" is always a valid answer, so there is
      // always something to pick between and the button always has a job.
      TransportButton {
        id: qualityButton
        visible: view.panel.qualityPickerAvailable
        width: view.panel.qualityPickerAvailable ? controlSize : 0
        // nf-md-quality_high — check any replacement against the resolved mono
        // Nerd Font; a missing glyph renders as a tofu box.
        glyphText: "\u{f07fd}"
        tooltipText: view.panel.qualityKbps === 0
          ? "Quality · Q · direct play"
          : "Quality · Q · " + Math.round(view.panel.qualityKbps / 1000) + " Mbps"
        foreground: view.foreground
        selected: view.panel.trackPopup === "quality"
        hasCursor: view.panel.cursorOn("playing", "quality")
        onClicked: view.panel.toggleTrackPopup("quality")
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.setPanelCursor("playing", "quality")
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
      // No hover box on the timeline: hover still claims the panel cursor and
      // the keyboard "seek" action stays reachable, but a rectangle snapping up
      // around the scrubber reads as a rendering defect rather than a
      // highlight. The knob carries the keyboard indication instead.
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

  // ---------- picker (audio / subtitles / quality) ----------
  // One list widget for all three: the row contract is identical (a label, a
  // current flag), and a second popup would mean a second Esc ordering to keep
  // in step with this one. Declared after the strip so it paints above it, and
  // click-away first so the list itself keeps its own clicks. Deliberately NOT
  // a QQC2 Popup: it wants no focus scope and no Shortcut objects, because the
  // panel's key dispatcher already gives it first refusal (see
  // handleTrackPopupKey) — one keyboard model instead of two competing ones.
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

        onClicked: view.panel.activatePickerRow(view.panel.trackPopup, modelData)
        onHovered: function(on) {
          view.panel.pokeTheaterControls()
          if (on) view.panel.trackPopupIndex = index
        }

        // Why this row cannot just be flipped in the running pipeline: a
        // sidecar the player cannot see, or an image subtitle Qt cannot draw.
        // Both mean the server has to build a new stream, which costs a
        // restart — worth saying before the click, not after.
        //
        // "burn-in" is a QtMultimedia-only warning — EITHER mpv engine renders
        // a muxed image subtitle itself — so the panel derives it from
        // rowNeedsServer rather than this delegate restating the condition.
        Text {
          anchors.right: rowCheck.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: modelData.external === true
            ? "server"
            : (view.panel.rowBurnsIn(modelData) ? "burn-in" : "")
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
