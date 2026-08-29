// Adapted from omarchy quickshell.spotify TransportButton.qml (MIT).
import QtQuick
import qs.Commons
import qs.Ui

// Transport glyphs have very different font advances and ink bounds
// (especially play/pause, shuffle and repeat). Give each one the same hit
// target and center its painted bounds so a Row produces an even rhythm.
Button {
  id: root

  property string glyphText: ""
  property real glyphSize: Style.font.icon
  property real controlSize: Style.space(32)

  width: controlSize
  height: controlSize
  horizontalPadding: 0
  verticalPadding: 0

  readonly property int renderedGlyphSize: Math.max(1, Math.round(glyphSize))
  readonly property real tightGlyphWidth: Math.max(1,
    glyphMetrics.tightBoundingRect.width)
  readonly property real tightGlyphHeight: Math.max(1,
    glyphMetrics.tightBoundingRect.height)

  TextMetrics {
    id: glyphMetrics
    font.family: root.fontFamily
    font.pixelSize: root.renderedGlyphSize
    text: root.glyphText
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: implicitWidth / 2
      - (glyphMetrics.tightBoundingRect.x + root.tightGlyphWidth / 2)
    anchors.verticalCenterOffset: implicitHeight / 2
      - (baselineOffset + glyphMetrics.tightBoundingRect.y
        + root.tightGlyphHeight / 2)
    text: root.glyphText
    font.family: root.fontFamily
    font.pixelSize: root.renderedGlyphSize
    renderType: Text.NativeRendering
    color: root.selected
      ? Style.selectedStateColor(root.foreground, root.accent)
      : root.foreground
  }
}
