import QtQuick
import qs.Commons
import qs.Ui

// Video-flavored take on the Spotify app's MediaRow: same panel-cursor
// fill model (selected/cursorOn only, never containsMouse) but a landscape
// art well sized for episode/CW thumbs instead of a square cover.
BorderSurface {
  id: root

  required property var itemData
  property bool selected: false
  property bool cursorOn: false
  property bool browseOnActivate: false
  property real artAspect: 16 / 9

  signal activated()
  signal openRequested()
  signal hovered(bool on)

  width: parent ? parent.width : implicitWidth
  implicitWidth: Style.space(420)
  implicitHeight: Style.space(56)
  height: implicitHeight
  radius: Style.cornerRadius
  // Zero-row-animation rule: fills snap between exactly these three states,
  // never containsMouse — cursorOn is fed by the panel's single-highlight
  // cursor model, not by this row's own hover.
  color: selected ? Style.selectedFillFor(Color.foreground, Color.accent)
    : (cursorOn ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent")
  clip: true

  HoverHandler {
    id: hoverHandler
    onHoveredChanged: root.hovered(hoverHandler.hovered)
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.browseOnActivate ? root.openRequested() : root.activated()
  }

  Item {
    id: contentRow
    anchors.fill: parent
    anchors.margins: Style.space(6)

    BorderSurface {
      id: artWell
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      width: height * root.artAspect
      radius: Style.spacing.labelGap
      color: Style.selectedFillFor(Color.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
      clip: true

      Image {
        id: rowArt
        anchors.fill: parent
        anchors.margins: Style.space(2)
        source: root.itemData && root.itemData.thumbPath ? root.itemData.thumbPath : ""
        sourceSize.width: artWell.width * 2
        sourceSize.height: artWell.height * 2
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Rows are recycled ListView delegates; never let Qt's shared
        // pixmap cache hoard every artwork this list has ever scrolled past.
        cache: false
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: rowArt.status !== Image.Ready
        text: {
          var type = root.itemData ? root.itemData.type : ""
          if (type === "show" || type === "season" || type === "episode") return "󰦔"
          if (type === "movie") return "󰎁"
          return "󰐊"
        }
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge
      }

      Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        height: Style.space(2)
        width: parent.width * Math.max(0, Math.min(1,
          root.itemData ? Number(root.itemData.progress) || 0 : 0))
        visible: root.itemData && Number(root.itemData.progress) > 0
        color: Color.accent
      }
    }

    Column {
      anchors.left: artWell.right
      anchors.leftMargin: Style.space(9)
      anchors.right: actionRow.left
      anchors.rightMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.itemData ? String(root.itemData.title || "Untitled") : "Untitled"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: root.selected
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.itemData ? String(root.itemData.sub || "") : ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        visible: text !== ""
      }
    }

    Row {
      id: actionRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        text: root.itemData ? String(root.itemData.durationText || "") : ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        // Play is a distinct action from "open" — but only for things the
        // resolver can actually play. A show/season ratingKey has no
        // Media/Part, so an always-visible ▶ there was an advertised action
        // that always landed in error mode (review finding).
        visible: root.itemData
          && (root.itemData.type === "movie" || root.itemData.type === "episode")
        iconText: "󰐊"
        iconSize: Style.font.body
        foreground: Color.foreground
        tooltipText: "Play · Enter"
        horizontalPadding: Style.space(7)
        onClicked: root.activated()
        // Single-highlight rule: hovering the inline button must move the
        // shared cursor to this row, or the kit Button's own containsMouse
        // paints a second highlight beside the keyboard's.
        onHovered: function(on) { if (on) root.hovered(true) }
      }
    }
  }
}
