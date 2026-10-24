import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Omarchy Plex bar widget.
//   idle    - the Plex glyph alone
//   playing - glyph + now-playing title; if it overflows maxTitleWidth it
//             rests at the start, slides to show the end, rests, slides
//             back, then rests longer (render-thread XAnimators)
//   paused  - glyph swaps to a pause glyph, title stays put (no marquee)
// Click always toggles the panel. Bar width is just implicitWidth off the
// content Row — the bar host reflows the layout on its own the moment this
// changes (plugins/bar/Bar.qml:1565), so nothing here animates size.
//
// Now-playing state comes from PlayerState.qml, this plugin's "service"
// entry point: the panel publishes {playing, paused, title} onto it, the
// shell hands every entry point of a plugin the SAME instance, and this
// widget reads it off `bar.shell.serviceFor(moduleName)` — identical to how
// quickshell.spotify's BarWidget.qml (line 16) reaches its own Service.qml.
BarWidget {
  id: root

  moduleName: "dot3x3q.omarchy-plex"

  readonly property var playerState: root.bar && root.bar.shell
    ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property bool isPlaying: !!(root.playerState && root.playerState.playing)
  readonly property bool isPaused: !!(root.playerState && root.playerState.paused)
  readonly property string mediaTitle: root.playerState
    ? String(root.playerState.title || "") : ""
  readonly property bool showTitle: root.isPlaying && root.mediaTitle !== ""

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string widgetFontFamily: root.bar && root.bar.fontFamily
    ? root.bar.fontFamily : Style.font.family
  // Pause glyph while paused, the Plex glyph otherwise (idle and playing).
  readonly property string glyphText: root.isPaused ? "󰏤" : "󰚺"

  readonly property real horizontalMargin: Style.space(8)
  readonly property real contentSpacing: Style.space(6)
  readonly property real maxTitleWidth: Style.space(180)

  implicitWidth: content.implicitWidth + root.horizontalMargin * 2
  implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  // Card-recipe hover/press surface: idle/hover/pressed alpha over foreground.
  Rectangle {
    id: surface
    anchors.fill: parent
    radius: Style.cornerRadius
    color: mouse.containsPress
      ? Style.pressedFillFor(root.foreground, Color.accent)
      : (mouse.containsMouse
        ? Style.hoverFillFor(root.foreground, Color.accent)
        : Style.normalFillFor(root.foreground, Color.accent))
  }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: root.showTitle ? root.contentSpacing : 0

    OpticalGlyph {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: Style.space(16)
      text: root.glyphText
      color: root.foreground
      fontFamily: root.widgetFontFamily
      fontSize: Style.bar.iconFont
    }

    // Marquee strip: only present while playing with a title.
    Item {
      id: scrollClip
      visible: root.showTitle
      width: root.showTitle ? Math.min(root.maxTitleWidth, label.implicitWidth) : 0
      height: glyph.height
      anchors.verticalCenter: parent.verticalCenter
      clip: label.needsScroll

      // Static while paused even if it would otherwise overflow.
      readonly property bool scrolling: label.needsScroll && root.isPlaying && !root.isPaused
      readonly property real fadeStop: width > 0 ? Math.min(0.2, Style.space(28) / width) : 0
      // How far the title has to travel to bring its last letter into view.
      readonly property real overflow: Math.max(0, label.implicitWidth - width)
      // Fade only the edge text is actually hidden behind: at rest on the
      // start the first letters must read cleanly, and at the end the last.
      property bool atStart: true
      property bool atEnd: false
      onScrollingChanged: { scrollClip.atStart = true; scrollClip.atEnd = false }

      // An Animation snapshots its XAnimators' from/to when it STARTS, and an
      // infinite loop never starts again — so a new, longer or shorter title
      // kept sliding by the previous title's overflow: the end of a long
      // title never came into view, or a short one slid into blank space.
      // Bouncing `running` off for one tick restarts the loop from rest on
      // the new numbers.
      property bool marqueeRestarting: false
      function restartMarquee() {
        if (!scrollClip.scrolling || scrollClip.marqueeRestarting) return
        scrollClip.marqueeRestarting = true
        scrollClip.atStart = true
        scrollClip.atEnd = false
        Qt.callLater(function() { scrollClip.marqueeRestarting = false })
      }
      onOverflowChanged: scrollClip.restartMarquee()

      Item {
        id: labelLayer
        anchors.fill: parent
        layer.enabled: scrollClip.scrolling
        layer.smooth: true
        layer.effect: MultiEffect {
          autoPaddingEnabled: false
          maskEnabled: true
          maskSource: scrollFadeMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1
        }

        Text {
          id: label
          anchors.verticalCenter: parent.verticalCenter
          text: root.mediaTitle
          // Server-controlled string: AutoText would promote HTML-looking
          // titles to rich text inside the shared shell process.
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.widgetFontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering

          readonly property bool needsScroll: implicitWidth > scrollClip.width

          // Render-thread marquee: XAnimator drives x off the render thread,
          // so it stays smooth without dispatching through the shared
          // shell's main thread (same reasoning as the Spotify bar widget).
          // A full wrap-around ticker never stopped moving, which was a lot to
          // have in the corner of the eye; this travels only the overflow and
          // spends most of its time still. The longer rest is on the start,
          // the part of the title that identifies it.
          // A new title while the overflow happens to be the same still
          // has to start from rest, not mid-slide.
          onTextChanged: scrollClip.restartMarquee()

          SequentialAnimation {
            running: scrollClip.scrolling && !scrollClip.marqueeRestarting
            loops: Animation.Infinite
            onStopped: label.x = 0

            PauseAnimation { duration: 4000 }
            ScriptAction { script: scrollClip.atStart = false }
            XAnimator {
              target: label
              from: 0
              to: -scrollClip.overflow
              duration: Math.round(Math.max(1200, scrollClip.overflow * 30))
              easing.type: Easing.InOutSine
            }
            ScriptAction { script: scrollClip.atEnd = true }
            PauseAnimation { duration: 2000 }
            ScriptAction { script: scrollClip.atEnd = false }
            XAnimator {
              target: label
              from: -scrollClip.overflow
              to: 0
              duration: Math.round(Math.max(1200, scrollClip.overflow * 30))
              easing.type: Easing.InOutSine
            }
            ScriptAction { script: scrollClip.atStart = true }
          }
        }
      }

      Rectangle {
        id: scrollFadeMask
        anchors.fill: parent
        visible: false
        layer.enabled: scrollClip.scrolling
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: scrollClip.atStart ? "white" : "transparent" }
          GradientStop { position: scrollClip.fadeStop; color: "white" }
          GradientStop { position: 1 - scrollClip.fadeStop; color: "white" }
          GradientStop { position: 1; color: scrollClip.atEnd ? "white" : "transparent" }
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle " + root.moduleName)
    }
  }
}
