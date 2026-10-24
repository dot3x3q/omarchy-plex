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
  // Root-owned and generation-checked (PlexPanel search()). Inferring it here
  // from onQueryChanged broke on Back: the rebuilt page saw its query
  // "change", armed Searching… with no request behind it, and zeroed the
  // remembered scroll.
  readonly property bool searching: page.panel.searching === true
  property int cursorIndex: 0
  // The cursor survives Back the same way the scroll does; restoring only
  // contentY left the highlight on row 0, off-screen.
  onCursorIndexChanged: page.panel.rememberScroll("search:cursor", page.cursorIndex)

  Component.onCompleted: {
    var n = page.resolvedResults.length
    page.cursorIndex = n > 0 ? Math.min(n - 1, Math.round(page.panel.scrollFor("search:cursor"))) : 0
  }

  // A new query is a new list: stale cursor/scroll positions point at rows
  // that are about to be replaced. Only a real search() says so.
  Connections {
    target: page.panel
    function onSearchStarted() {
      page.cursorIndex = 0
      resultsList.contentY = 0
    }
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

  // PageUp/PageDown clamp at the ends. Wrapping is right for a single step
  // (above), but a five-row jump that lands back at the top reads as lost.
  function bulkMove(delta) {
    var items = page.resolvedResults
    if (items.length === 0) return
    page.cursorIndex = Math.max(0, Math.min(items.length - 1, page.cursorIndex + delta))
    page.scrollIntoView()
  }
  function pageUp() { page.bulkMove(-5) }
  function pageDown() { page.bulkMove(5) }

  function scrollIntoView() { resultsList.positionViewAtIndex(page.cursorIndex, ListView.Contain) }

  // Results are root-owned; R re-runs the query (the retry the failure
  // message offers).
  function reload() {
    if (page.query !== "") page.panel.search(page.query)
  }

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
      : (page.searching ? "Searching…"
        : (page.panel.searchFailed ? "Couldn't search — R to retry" : "No results."))
  }

  // While a refinement is in flight over existing results, say so — the
  // centered empty-state label only covers the zero-results case.
  Text {
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(4)
    z: 10
    visible: page.searching && resultsList.count > 0
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    text: "Searching…"
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

    // parent: is load-bearing. Declared bare inside a Flickable, the handler
    // becomes a child of contentItem and scrolls away with the content: the
    // fast wheel then only works on the first screen and onScrolled stops
    // firing (verified offscreen). The Spotify plugin parents every one.
    FastScrollHandler { parent: resultsList; flickable: resultsList }

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
