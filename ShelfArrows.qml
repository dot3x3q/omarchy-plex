import QtQuick
import qs.Commons
import qs.Ui

// The ‹ › pair stock Plex puts top-right of every horizontal row: pages the
// row one view-width at a time. A mouse has no other way along a shelf
// without a horizontal wheel, so every horizontal row in the app gets one —
// Home's shelves, the detail page's cast/extras/related and the season picker.
//
// The arrows are pointer-only controls (no keyboard slot; h/l already walk
// the row). The kit Button paints its own hover, so each one claims the
// panel's "pointer" pseudo-region while hovered: the page cursor hides, and
// returns where it was on leave — one highlight on screen, never two.
Row {
  id: arrows

  required property var list
  required property var panel
  // Unique per row on the page, e.g. "shelf:1" or "detail:cast".
  required property string key
  // The smallest sensible step: one card. A page is the view width minus one
  // card, so the card at the edge stays visible as a landmark.
  property real cardWidth: Style.space(120)

  spacing: Style.space(2)
  // Only once the row actually overflows; a short row has nowhere to go.
  visible: arrows.list.visible && arrows.list.contentWidth > arrows.list.width + 1

  function pageRow(dir) {
    var l = arrows.list
    var minX = Number(l.originX) || 0
    var maxX = Math.max(minX, minX + l.contentWidth - l.width)
    var step = Math.max(arrows.cardWidth, l.width - arrows.cardWidth)
    rowScroll.to = Math.max(minX, Math.min(maxX, l.contentX + dir * step))
    rowScroll.restart()
  }

  NumberAnimation {
    id: rowScroll
    target: arrows.list
    property: "contentX"
    duration: 260
    easing.type: Easing.OutCubic
  }

  Button {
    iconText: "󰅁"
    iconSize: Style.font.iconLarge
    foreground: Color.foreground
    focusable: false
    bordered: false
    horizontalPadding: Style.space(5)
    enabled: !arrows.list.atXBeginning
    opacity: enabled ? 1 : 0.35
    tooltipText: "Scroll left · Shift+wheel"
    hasCursor: arrows.panel.cursorOn("pointer", arrows.key + ":prev")
    onClicked: arrows.pageRow(-1)
    onHovered: function(on) {
      if (on) arrows.panel.claimPointer(arrows.key + ":prev")
      else arrows.panel.releasePointer(arrows.key + ":prev")
    }
  }

  Button {
    iconText: "󰅂"
    iconSize: Style.font.iconLarge
    foreground: Color.foreground
    focusable: false
    bordered: false
    horizontalPadding: Style.space(5)
    enabled: !arrows.list.atXEnd
    opacity: enabled ? 1 : 0.35
    tooltipText: "Scroll right · Shift+wheel"
    hasCursor: arrows.panel.cursorOn("pointer", arrows.key + ":next")
    onClicked: arrows.pageRow(1)
    onHovered: function(on) {
      if (on) arrows.panel.claimPointer(arrows.key + ":next")
      else arrows.panel.releasePointer(arrows.key + ":next")
    }
  }
}
