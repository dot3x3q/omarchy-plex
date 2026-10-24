pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "Api.js" as Api

// Poster-grid browser for one library section (panel.pageParams.sectionId).
// PlexPanel.showPage() rebuilds the page on every navigation, so a section
// switch normally arrives as a fresh instance. trySync() still watches
// panel.pageParams so an in-place params change (if one ever returns) keeps
// working rather than showing the wrong library.
Item {
  id: root

  required property var panel

  readonly property string sectionId: String(
    panel.pageParams && panel.pageParams.sectionId !== undefined ? panel.pageParams.sectionId : "")
  readonly property bool cursorHere: panel.cursorRegion === "page"
  readonly property string scrollKey: "library:" + root.sectionId + ":" + root.sortKey

  // ---- sort ----
  // All three sort keys are honored server-side; no client re-sort needed.
  readonly property var sortKeys: ["addedAt:desc", "titleSort", "year:desc"]
  property string sortKey: root.sortKeys[0]

  function sortLabel() {
    if (root.sortKey === "titleSort") return "Title"
    if (root.sortKey === "year:desc") return "Year"
    return "Recently added"
  }

  function cycleSort() {
    // Bank the scroll position under the OLD key before it changes out from
    // under gridView's contentY.
    root.saveView()
    var idx = root.sortKeys.indexOf(root.sortKey)
    root.sortKey = root.sortKeys[(idx + 1) % root.sortKeys.length]
    root.resetAndFetch()
  }

  // ---- pagination ----
  readonly property int pageSize: 60
  // `items` is the data; `gridModel` is what the GridView watches, holding one
  // placeholder row per item. Reassigning a JS array as a view's model is a model
  // RESET: the GridView throws every delegate away and snaps contentY back to
  // the top. That was the "scrolling slowly, hit the bottom, get thrown to the
  // top" bug — every next page reset the view. ListModel.append() inserts rows
  // instead, so the grid grows under the reader without moving.
  property var items: []
  ListModel { id: gridModel }
  property int nextStart: 0
  property int totalCount: -1
  property bool loading: false
  property bool hasMore: true
  property bool loadedOnce: false
  property string loadedSectionId: ""
  // A null response is a transport/auth failure, not the end of the library.
  // It used to read as one: mapItems(null) is [], so hasMore went false and
  // totalCount -1, and the grid silently ended at 240 with the count gone.
  property bool loadFailed: false

  readonly property int itemCount: root.totalCount >= 0 ? root.totalCount : root.items.length
  // Nothing to count until the first page lands; "0 items" over a loading
  // grid read as an empty library.
  readonly property string countText: root.totalCount < 0 && root.items.length === 0
    ? "" : root.itemCount + (root.itemCount === 1 ? " item" : " items")

  // Resolve section switches: called from Component.onCompleted, onWidthChanged
  // (width can still be 0 the instant this Item is created) and whenever the
  // root panel hands us new pageParams for an already-alive instance.
  function trySync() {
    if (root.width <= 0) return
    if (root.sectionId === root.loadedSectionId && root.loadedOnce) return
    if (root.loadedOnce) root.saveView()
    root.loadedSectionId = root.sectionId
    root.sortKey = root.sortKeys[0]
    root.resetAndFetch()
  }

  // Kills in-flight responses from a section/sort already left; without it a
  // slow Movies page 0 lands under the TV Shows title and corrupts pagination.
  property int fetchGen: 0

  function resetAndFetch() {
    root.fetchGen++
    root.loading = false
    root.items = []
    gridModel.clear()
    root.nextStart = 0
    root.totalCount = -1
    root.hasMore = true
    root.loadFailed = false
    root.loadedOnce = false
    root.restoreApplied = false
    gridView.currentIndex = -1
    root.fetchPage()
  }

  // R after a failed page retries THAT page and keeps everything already on
  // screen; otherwise it is a full refresh.
  function reload() {
    if (root.loadFailed && root.items.length > 0) {
      root.loadFailed = false
      root.fetchPage()
      return
    }
    root.resetAndFetch()
  }

  function fetchPage() {
    if (root.loading || !root.hasMore || root.loadFailed || root.sectionId === "") return
    root.loading = true
    // Empty server arg gets us back a bare path — libraryAllUrl always
    // prepends its server param, and panel.request(path, cb) prepends
    // panel.server itself, so a path here must NOT already carry a host.
    var path = Api.libraryAllUrl("", root.sectionId,
      { sort: root.sortKey, start: root.nextStart, size: root.pageSize })
    var thumbW = root.thumbW
    var thumbH = root.thumbH
    var gen = root.fetchGen
    panel.request(path, function(doc) {
      if (gen !== root.fetchGen) return
      root.loading = false
      if (doc === null || doc === undefined) {
        // Keep hasMore, totalCount and nextStart as they were, so a retry
        // asks for exactly this page again.
        root.loadFailed = true
        return
      }
      var mc = doc && doc.MediaContainer
      var total = mc && mc.totalSize !== undefined ? Number(mc.totalSize) : -1
      // Image-URL handoff: Api.js hands back raw, unauthenticated paths —
      // this page resolves them at fetch time since it is the one that knows
      // the display size.
      var batch = Api.mapItems(doc).map(function(it) {
        return Object.assign({}, it, { thumbPath: panel.imageUrl(it.thumbPath, thumbW, thumbH) })
      })
      root.items = root.items.concat(batch)
      for (var b = 0; b < batch.length; b++) gridModel.append({ slot: 0 })
      root.nextStart = root.nextStart + root.pageSize
      root.totalCount = total
      root.hasMore = batch.length >= root.pageSize && (total < 0 || root.items.length < total)
      root.loadedOnce = true
      if (gridView.currentIndex < 0 && root.items.length > 0) gridView.currentIndex = 0
      root.restoreView()
      // The first page can land shorter than one screenful (small library,
      // tall window) — top it up immediately rather than waiting for a
      // scroll event that will never come.
      Qt.callLater(root.maybeLoadMore)
    })
  }

  function maybeLoadMore() {
    if (root.loading || !root.hasMore || root.loadFailed) return
    if (gridView.atYEnd || gridView.contentHeight <= gridView.height) root.fetchPage()
  }

  // ---- grid geometry ----
  // Columns come from the available width; cellHeight mirrors PosterCard's own
  // height formula (poster + text block), because GridView needs a number
  // before the delegate ever lays out.
  readonly property int columns: gridView.width > 0
    ? Math.max(2, Math.floor(gridView.width / Style.space(132))) : 2
  readonly property int cellW: gridView.width > 0
    ? Math.floor(gridView.width / root.columns) : Style.space(132)
  readonly property int posterW: Math.max(1, root.cellW - Style.space(12))
  readonly property int posterH: Math.round(root.posterW * 3 / 2)
  readonly property int cellH: root.posterH + root.textBlockHeight() + Style.space(6) + Style.space(8)
  readonly property int thumbW: root.posterW * 2
  readonly property int thumbH: root.posterH * 2

  function textBlockHeight() {
    var titleLine = Math.ceil(Style.font.body * 1.25)
    var captionLine = Math.ceil(Style.font.caption * 1.25)
    return Style.space(4) + titleLine + Style.space(2) + captionLine
  }

  // ---- keyboard ----
  // dx/dy arrive pre-resolved by the root (h/l -> dx, j/k -> dy). Horizontal
  // moves walk the FLAT item list, so `l` on the last column flows into the
  // next row's first item and `h` on a row's first flows back to the previous
  // row's last — it reads like text-cursor movement. Vertical moves clamp
  // instead of wrapping: a same-column step off the top or bottom edge has no
  // sane target, so it is a no-op rather than a jump to an unrelated column.
  // Where a keyboard step starts. If the wheel has carried the cursor's cell
  // out of view, the step starts from the first visible poster instead —
  // otherwise one "l" after scrolling (or after a restore that brought back
  // the scroll but not a cursor) yanks the grid back to the old spot.
  function cursorStart() {
    var cur = gridView.currentIndex < 0 ? 0 : gridView.currentIndex
    var rowTop = Math.floor(cur / root.columns) * gridView.cellHeight + gridView.originY
    if (rowTop + gridView.cellHeight > gridView.contentY && rowTop < gridView.contentY + gridView.height) return cur
    var top = gridView.indexAt(gridView.cellWidth / 2, gridView.contentY + gridView.cellHeight / 2)
    return top >= 0 ? top : cur
  }

  function moveCursor(dx, dy) {
    var count = gridView.count
    if (count === 0) return
    var cur = root.cursorStart()
    if (cur !== gridView.currentIndex) { gridView.currentIndex = cur; return }
    var next = cur
    if (dx !== 0) next = cur + dx
    else if (dy !== 0) next = cur + dy * root.columns
    if (next < 0 || next >= count) return
    gridView.currentIndex = next
    gridView.positionViewAtIndex(next, GridView.Contain)
  }

  function activateCursor() {
    var idx = gridView.currentIndex
    if (idx < 0 || idx >= root.items.length) return
    root.openDetail(root.items[idx])
  }

  function openDetail(it) {
    if (!it) return
    panel.navigate("detail",
      { ratingKey: it.ratingKey, title: it.title, subtitle: it.caption, type: it.type })
  }

  function rowsPerScreen() {
    var ch = gridView.cellHeight > 0 ? gridView.cellHeight : 1
    return Math.max(1, Math.floor(gridView.height / ch))
  }

  function stepRows(rows) {
    var count = gridView.count
    if (count === 0) return
    var cur = root.cursorStart()
    var next = Math.max(0, Math.min(count - 1, cur + rows * root.columns))
    gridView.currentIndex = next
    gridView.positionViewAtIndex(next, GridView.Contain)
  }

  // "s" cycles the sort, the keyboard twin of the sort button (DESIGN.md
  // keyboard model). Dispatched from PlexPanel.handleKey.
  function handlePageKey(text) {
    if (text === "s") { root.cycleSort(); return true }
    return false
  }

  function pageUp() { root.stepRows(-root.rowsPerScreen()) }
  function pageDown() { root.stepRows(root.rowsPerScreen()) }

  // ---- scroll + cursor memory ----
  // Both are banked per section+sort. Restoring scroll alone left the cursor
  // on item 0 — off-screen — so the first keypress after Back yanked the
  // grid to the top.
  property bool restoreApplied: false

  function saveView() {
    panel.rememberScroll(root.scrollKey, gridView.contentY)
    if (gridView.currentIndex >= 0) panel.rememberScroll(root.scrollKey + ":cursor", gridView.currentIndex)
  }

  function restoreView() {
    if (root.restoreApplied) return
    restoreTimer.restart()
  }

  Timer {
    id: restoreTimer
    interval: 0
    onTriggered: {
      if (root.restoreApplied) return
      if (gridView.count <= 0) return
      var target = root.panel.scrollFor(root.scrollKey)
      var want = Math.round(root.panel.scrollFor(root.scrollKey + ":cursor"))
      var maxY = Math.max(gridView.originY, gridView.contentHeight - gridView.height + gridView.originY)
      // Only page 1 exists when Back rebuilds this page. Clamping the target
      // to it and calling the restore done threw a reader at item 300 back
      // to ~item 40 (verified: 10206 → 1533). Keep paging until the
      // remembered spot exists; each landed page re-arms this timer.
      if ((target > maxY || want >= root.items.length) && root.hasMore && !root.loadFailed) {
        root.fetchPage()
        return
      }
      gridView.contentY = Math.max(gridView.originY, Math.min(maxY, target))
      if (root.items.length > 0) gridView.currentIndex = Math.max(0, Math.min(root.items.length - 1, want))
      root.restoreApplied = true
    }
  }

  Component.onCompleted: root.trySync()
  onWidthChanged: root.trySync()
  Component.onDestruction: {
    root.saveView()
    // Responses for a page already left return at their gen check.
    root.fetchGen++
  }

  Connections {
    target: root.panel
    function onPageParamsChanged() { root.trySync() }
  }

  // ---- tools row ----
  Item {
    id: toolsRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(38)

    Button {
      id: sortButton
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰒺"
      text: root.sortLabel()
      foreground: Color.foreground
      tooltipText: "Change sort order · S"
      hasCursor: root.panel.cursorOn("pointer", "library-sort")
      onClicked: root.cycleSort()
      // Pointer-only control: claiming hides the grid cursor while the kit
      // Button paints its own hover, so only one highlight shows.
      onHovered: function(on) {
        if (on) root.panel.claimPointer("library-sort")
        else root.panel.releasePointer("library-sort")
      }
    }

    Text {
      id: countLabel
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.countText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }
  }

  GridView {
    id: gridView
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: toolsRow.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    // The paginating footer floats at the page bottom; reserve its strip so
    // "Loading more…" never overlaps the last poster row.
    anchors.bottomMargin: (root.loading || root.loadFailed) && root.items.length > 0 ? Style.space(24) : 0
    clip: true
    visible: root.items.length > 0
    reuseItems: true
    cacheBuffer: Style.space(160)
    keyNavigationEnabled: false
    highlightFollowsCurrentItem: false
    cellWidth: root.cellW
    cellHeight: root.cellH
    model: gridModel
    onContentYChanged: root.maybeLoadMore()
    // Only once restored: before that, currentIndex is the fetch's default 0
    // and banking it would overwrite the spot being restored.
    onCurrentIndexChanged: if (root.restoreApplied && currentIndex >= 0)
      root.panel.rememberScroll(root.scrollKey + ":cursor", currentIndex)
    // Deferred, not direct: the "Loading more…" footer's bottomMargin depends
    // on `loading`, so a fetch started from inside a height change resizes the
    // grid again mid-binding — Qt reported it as a bottomMargin binding loop.
    onWidthChanged: Qt.callLater(root.maybeLoadMore)
    onHeightChanged: Qt.callLater(root.maybeLoadMore)

    delegate: Item {
      id: cell
      required property int index
      readonly property var modelData: root.items[cell.index]
      width: gridView.cellWidth
      height: gridView.cellHeight

      PosterCard {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(6)
        itemData: cell.modelData
        cursorOn: cell.index === gridView.currentIndex && root.cursorHere
        onHovered: function(on) {
          if (on) { gridView.currentIndex = cell.index; root.panel.setPanelCursor("page", "") }
        }
        onActivated: {
          gridView.currentIndex = cell.index
          root.openDetail(cell.modelData)
        }
      }
    }

    // parent: keeps the handler on the viewport rather than inside
    // contentItem, where it scrolls away after the first screen and the
    // onScrolled scroll-memory hook stops firing.
    FastScrollHandler {
      parent: gridView
      flickable: gridView
      onScrolled: root.panel.rememberScroll(root.scrollKey, gridView.contentY)
    }
  }

  // Empty/loading: same muted centered label, different sentence — the
  // kit's "no spinners" rule (DESIGN.md).
  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: toolsRow.bottom
    anchors.topMargin: Style.space(24)
    visible: root.items.length === 0
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
    text: root.loading
      ? "Loading " + root.panel.libraryTitle(root.sectionId) + "…"
      : (root.loadFailed ? "Couldn't load " + root.panel.libraryTitle(root.sectionId) + " — R to retry"
        : "This library is empty.")
  }

  // Paginating footer — text only, matching the no-spinner rule.
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
    visible: (root.loading || root.loadFailed) && root.items.length > 0
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    text: root.loadFailed ? "Couldn't load more — R to retry" : "Loading more…"
  }
}
