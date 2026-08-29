import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

// Omarchy Plex bar widget.
//   idle    - the Plex glyph alone
//   playing - glyph + now-playing title, marquee (render-thread XAnimator,
//             Spotify-style) if the title overflows maxTitleWidth
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
          color: root.foreground
          font.family: root.widgetFontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering

          readonly property bool needsScroll: implicitWidth > scrollClip.width

          // Render-thread marquee: XAnimator drives x off the render thread,
          // so it stays smooth without dispatching through the shared
          // shell's main thread (same reasoning as the Spotify bar widget).
          XAnimator on x {
            running: scrollClip.scrolling
            loops: Animation.Infinite
            duration: Math.round(Math.max(6000, label.implicitWidth * 25))
            from: scrollClip.width
            to: -label.implicitWidth
            easing.type: Easing.Linear
            onStopped: label.x = 0
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
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: scrollClip.fadeStop; color: "white" }
          GradientStop { position: 1 - scrollClip.fadeStop; color: "white" }
          GradientStop { position: 1; color: "transparent" }
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
