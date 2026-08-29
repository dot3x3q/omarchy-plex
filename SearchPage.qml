import QtQuick
import qs.Commons

// Wave-1 placeholder. Wave 2 (Agent D) replaces this with row results for the
// global search box owned by the root panel.
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
