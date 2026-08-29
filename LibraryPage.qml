pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "Api.js" as Api

// Poster-grid browser for one library section (panel.pageParams.sectionId).
// The root panel's page Loader keeps this SAME instance alive across two
// library sections in a row (its sourceComponent only changes when
// currentPage itself changes, not pageParams — see PlexPanel.qml
// pageComponent()), so section switches are driven by watching
// panel.pageParams, not by Component.onCompleted alone.
Item {
  id: root

  required property var panel

  readonly property string sectionId: String(
    panel.pageParams && panel.pageParams.sectionId !== undefined ? panel.pageParams.sectionId : "")
  readonly property bool cursorHere: panel.cursorRegion === "page"
  readonly property string scrollKey: "library:" + root.sectionId + ":" + root.sortKey

  // ---- sort ----
  // Verified live against the server (docs/PLEX-API.md): all three honored
  // server-side, no client re-sort needed.
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
    panel.rememberScroll(root.scrollKey, gridView.contentY)
    var idx = root.sortKeys.indexOf(root.sortKey)
    root.sortKey = root.sortKeys[(idx + 1) % root.sortKeys.length]
    root.resetAndFetch()
  }

  // ---- pagination ----
  readonly property int pageSize: 60
  property var items: []
  property int nextStart: 0
  property int totalCount: -1
  property bool loading: false
  property bool hasMore: true
  property bool loadedOnce: false
  property string loadedSectionId: ""

  readonly property int itemCount: root.totalCount >= 0 ? root.totalCount : root.items.length

  // Resolve section switches: called from Component.onCompleted, onWidthChanged
  // (width can still be 0 the instant this Item is created) and whenever the
  // root panel hands us new pageParams for an already-alive instance.
  function trySync() {
    if (root.width <= 0) return
    if (root.sectionId === root.loadedSectionId && root.loadedOnce) return
    if (root.loadedOnce) panel.rememberScroll(root.scrollKey, gridView.contentY)
    root.loadedSectionId = root.sectionId
    root.sortKey = root.sortKeys[0]
    root.resetAndFetch()
  }

  function resetAndFetch() {
    root.items = []
    root.nextStart = 0
    root.totalCount = -1
    root.hasMore = true
    root.loadedOnce = false
    root.restoreApplied = false
    gridView.currentIndex = -1
    root.fetchPage()
  }

  function reload() {
    root.resetAndFetch()
  }

  function fetchPage() {
    if (root.loading || !root.hasMore || root.sectionId === "") return
    root.loading = true
    // Empty server arg gets us back a bare path — libraryAllUrl always
    // prepends its server param, and panel.request(path, cb) prepends
    // panel.server itself, so a path here must NOT already carry a host.
    var path = Api.libraryAllUrl("", root.sectionId,
      { sort: root.sortKey, start: root.nextStart, size: root.pageSize })
    var thumbW = root.thumbW
    var thumbH = root.thumbH
    panel.request(path, function(doc) {
      root.loading = false
      var mc = doc && doc.MediaContainer
      var total = mc && mc.totalSize !== undefined ? Number(mc.totalSize) : -1
      // Image-URL handoff (BUILD-CONTRACT.md): Api.js hands back raw,
      // unauthenticated paths — this page resolves them at fetch time since
      // it is the one that knows the display size.
      var batch = Api.mapItems(doc).map(function(it) {
        return Object.assign({}, it, { thumbPath: panel.imageUrl(it.thumbPath, thumbW, thumbH) })
      })
      root.items = root.items.concat(batch)
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
    if (root.loading || !root.hasMore) return
    if (gridView.atYEnd || gridView.contentHeight <= gridView.height) root.fetchPage()
  }

  // ---- grid geometry ----
  // Exact formulas from the build contract: columns from available width,
  // cellHeight mirrors PosterCard's own height formula (poster + text block)
  // since GridView needs a number before the delegate ever lays out.
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

  // ---- keyboard (page contract) ----
  // dx/dy arrive pre-resolved by the root (h/l -> dx, j/k -> dy). Horizontal
  // moves walk the flat item list, which is what makes `l` on the last
  // column flow into the next row's first item and `h` on a row's first
  // item flow back into the previous row's last — chosen over a hard
  // per-row stop because it reads like text-cursor movement, and Spotify's
  // own list cursor (Api.listIndexAfterMove) is exactly this: a flat index
  // walk, just one column wide there. Vertical moves clamp instead of
  // wrapping: a same-column step off the top/bottom edge has no sane target
  // (there is no row above the first), so it's a no-op rather than a jump
  // to an unrelated column.
  function moveCursor(dx, dy) {
    var count = gridView.count
    if (count === 0) return
    var cur = gridView.currentIndex < 0 ? 0 : gridView.currentIndex
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
    var cur = gridView.currentIndex < 0 ? 0 : gridView.currentIndex
    var next = Math.max(0, Math.min(count - 1, cur + rows * root.columns))
    gridView.currentIndex = next
    gridView.positionViewAtIndex(next, GridView.Contain)
  }

  function pageUp() { root.stepRows(-root.rowsPerScreen()) }
  function pageDown() { root.stepRows(root.rowsPerScreen()) }

  // ---- scroll memory ----
  property bool restoreApplied: false

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
      var maxY = Math.max(gridView.originY, gridView.contentHeight - gridView.height + gridView.originY)
      gridView.contentY = Math.max(gridView.originY, Math.min(maxY, target))
      root.restoreApplied = true
    }
  }

  Component.onCompleted: root.trySync()
  onWidthChanged: root.trySync()
  Component.onDestruction: panel.rememberScroll(root.scrollKey, gridView.contentY)

  Connections {
    target: root.panel
    function onPageParamsChanged() { root.trySync() }
  }

  // ---- tools row (Spotify MediaCollection style) ----
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
      tooltipText: "Change sort order"
      onClicked: root.cycleSort()
    }

    Text {
      id: countLabel
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.itemCount + (root.itemCount === 1 ? " item" : " items")
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
    // "Loading more…" never overlaps the last poster row (audit finding).
    anchors.bottomMargin: root.loading && root.items.length > 0 ? Style.space(24) : 0
    clip: true
    visible: root.items.length > 0
    reuseItems: true
    cacheBuffer: Style.space(160)
    keyNavigationEnabled: false
    highlightFollowsCurrentItem: false
    cellWidth: root.cellW
    cellHeight: root.cellH
    model: root.items
    onContentYChanged: root.maybeLoadMore()
    onWidthChanged: root.maybeLoadMore()
    onHeightChanged: root.maybeLoadMore()

    delegate: Item {
      id: cell
      required property var modelData
      required property int index
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

    FastScrollHandler {
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
      : "This library is empty."
  }

  // Paginating footer — text only, matching the no-spinner rule.
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
    visible: root.loading && root.items.length > 0
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    text: "Loading more…"
  }
}
