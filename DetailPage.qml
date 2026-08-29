import QtQuick
import qs.Commons

// Wave-1 placeholder. Wave 2 (Agent F) replaces this with the dimmed-backdrop
// hero plus Play/Resume, and season/episode drill-down for shows
// (panel.pageParams.ratingKey).
Item {
  id: page

  required property var panel

  // Page contract — no-ops until the real page lands.
  function moveCursor(dx, dy) {}
  function activateCursor() {}
  function pageUp() {}
  function pageDown() {}
  // Optional: the header refresh button calls this when present.
  function reload() {}

  Text {
    anchors.centerIn: parent
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    text: "…"
  }
}
