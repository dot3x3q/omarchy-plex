import QtQuick
import qs.Commons

// Plex Mini bar widget: click toggles the panel.
Item {
  id: root

  property var bar: null
  property string moduleName: "io.github.joshuaswarren.plexmini"
  property var settings: ({})

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color accent: Color.accent

  implicitWidth: label.implicitWidth + 24
  implicitHeight: root.bar ? root.bar.barSize : 26

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: mouse.containsPress ? root.accent : "transparent"
    opacity: mouse.containsMouse && !mouse.containsPress ? 0.75 : 1

    Text {
      id: label
      anchors.centerIn: parent
      color: mouse.containsPress ? Color.background : root.foreground
      text: "󰐊 Plex"
      font.pixelSize: 12
      font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : "monospace"
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!root.bar) return
        root.bar.run("omarchy-shell shell toggle io.github.joshuaswarren.plexmini")
      }
    }
  }
}
