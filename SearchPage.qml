import QtQuick
import qs.Commons

// Global search results. The root owns fetching (debounced search() in
// PlexPanel.qml fills panel.searchResults); this page only resolves
// thumbnails for display and renders rows.
Item {
  id: page

  required property var panel

  readonly property bool cursorHere: panel.cursorRegion === "page"
  readonly property string query: String((panel.pageParams && panel.pageParams.query) || "")
  // No explicit "request in flight" flag exists on the root, so this page
  // infers it locally: a new (non-empty) query arms "searching", and it
  // clears the moment ANY searchResults update lands. A slower stale
  // request finishing after a faster newer one is a known, accepted race —
  // pre-existing in root.search(), not something this page can fix without
  // the root gaining request-generation tracking.
  property bool searching: false
  property int cursorIndex: 0

  onQueryChanged: if (page.query !== "") page.searching = true

  Connections {
    target: page.panel
    function onSearchResultsChanged() { page.searching = false }
  }

  // Image-URL handoff: resolve thumbPath per row at fetch/render time
  // without mutating panel.searchResults in place. Poster-shaped types
  // (movie/show/season) keep their natural 2:3 thumb inside the row's art
  // well; only episodes are naturally landscape.
  function resolveItem(it) {
    var aspect = it.type === "episode" ? 16 / 9 : 2 / 3
    var h = Style.space(56)
    var w = Math.round(h * aspect)
    return Object.assign({}, it, { thumbPath: page.panel.imageUrl(it.thumbPath, w * 2, h * 2) })
  }

  readonly property var resolvedResults: {
    var raw = page.panel.searchResults || []
    var out = []
    for (var i = 0; i < raw.length; i++) out.push(page.resolveItem(raw[i]))
    return out
  }

  onResolvedResultsChanged: page.cursorIndex = Math.max(0, Math.min(page.resolvedResults.length - 1, page.cursorIndex))

  // Spotify-style wraparound: stepping past either end lands on the other.
  function moveCursor(dx, dy) {
    if (dy === 0) return
    var items = page.resolvedResults
    if (items.length === 0) return
    var next = (page.cursorIndex + dy) % items.length
    if (next < 0) next += items.length
    page.cursorIndex = next
    page.scrollIntoView()
  }

  function activateCursor() {
    var it = page.resolvedResults[page.cursorIndex]
    if (!it) return
    if (it.type === "episode") page.panel.playItem(it.ratingKey, it.title)
    else page.panel.navigate("detail", { ratingKey: it.ratingKey, title: it.title, subtitle: it.caption, type: it.type })
  }

  function bulkMove(delta) {
    var items = page.resolvedResults
    if (items.length === 0) return
    page.cursorIndex = ((page.cursorIndex + delta) % items.length + items.length) % items.length
    page.scrollIntoView()
  }
  function pageUp() { page.bulkMove(-5) }
  function pageDown() { page.bulkMove(5) }

  function scrollIntoView() { resultsList.positionViewAtIndex(page.cursorIndex, ListView.Contain) }

  // Nothing for this page to refetch on its own — results are root-owned.
  function reload() {}

  Text {
    anchors.centerIn: parent
    width: parent.width * 0.8
    visible: resultsList.count === 0
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
    text: page.query === ""
      ? "Type to search your whole server."
      : (page.searching ? "Searching…" : "No results.")
  }

  ListView {
    id: resultsList
    anchors.fill: parent
    visible: count > 0
    model: page.resolvedResults
    spacing: Style.space(3)
    clip: true
    reuseItems: true
    cacheBuffer: Style.space(160)

    Component.onCompleted: resultsList.contentY = page.panel.scrollFor("search")
    onContentYChanged: page.panel.rememberScroll("search", contentY)
    Component.onDestruction: page.panel.rememberScroll("search", resultsList.contentY)

    FastScrollHandler { flickable: resultsList }

    delegate: MediaRow {
      required property var modelData
      required property int index
      width: resultsList.width
      itemData: modelData
      artAspect: modelData.type === "episode" ? 16 / 9 : 2 / 3
      // Episodes play directly; movie/show/season rows open the detail
      // page — the row's own ▶ button always plays regardless (MediaRow
      // contract: activated() fires from that button no matter what).
      browseOnActivate: modelData.type !== "episode"
      selected: page.cursorHere && index === page.cursorIndex
      cursorOn: page.cursorHere && index === page.cursorIndex
      onActivated: page.panel.playItem(modelData.ratingKey, modelData.title)
      onOpenRequested: page.panel.navigate("detail", { ratingKey: modelData.ratingKey, title: modelData.title, subtitle: modelData.caption, type: modelData.type })
      onHovered: function(on) {
        if (on) { page.cursorIndex = index; page.panel.setPanelCursor("page", "") }
      }
    }
  }
}
