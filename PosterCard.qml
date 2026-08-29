import QtQuick
import qs.Commons
import qs.Ui

// Grid cell for poster libraries/shelves. Root stays a plain Item (not
// BorderSurface) per contract — the hover wash is one surface spanning
// poster + text so the whole card reads as a single hit target.
Item {
  id: root

  required property var itemData
  property bool cursorOn: false

  signal activated()
  signal hovered(bool on)

  readonly property real posterHeight: width * 3 / 2

  height: posterHeight + textBlock.height + Style.space(6)

  BorderSurface {
    id: cardSurface
    anchors.fill: parent
    radius: Style.cornerRadius
    // Same zero-animation fill rule as MediaRow: cursorOn is the panel's
    // single-highlight cursor, never this item's own hover state.
    color: root.cursorOn ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
  }

  HoverHandler {
    id: hoverHandler
    onHoveredChanged: root.hovered(hoverHandler.hovered)
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  BorderSurface {
    id: posterWell
    anchors.top: parent.top
    width: parent.width
    height: root.posterHeight
    radius: Style.spacing.labelGap
    color: Style.selectedFillFor(Color.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
    clip: true

    Image {
      id: posterArt
      anchors.fill: parent
      anchors.margins: Style.space(2)
      source: root.itemData && root.itemData.thumbPath ? root.itemData.thumbPath : ""
      sourceSize.width: posterWell.width * 2
      sourceSize.height: posterWell.height * 2
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: status === Image.Ready
    }

    Text {
      anchors.centerIn: parent
      visible: posterArt.status !== Image.Ready
      text: root.itemData && root.itemData.type === "show" ? "󰦔" : "󰎁"
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
    id: textBlock
    anchors.top: posterWell.bottom
    anchors.topMargin: Style.space(4)
    width: parent.width
    spacing: Style.space(2)

    Text {
      width: parent.width
      text: root.itemData ? String(root.itemData.title || "Untitled") : "Untitled"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.itemData ? String(root.itemData.caption || "") : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      visible: text !== ""
    }
  }
}
