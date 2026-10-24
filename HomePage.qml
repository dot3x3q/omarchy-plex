import QtQuick
import qs.Commons
import qs.Ui
import "Api.js" as Api

// Landing page (DESIGN.md: "Continue Watching + Recently Added"). One
// vertical Flickable holds two kinds of section: the On Deck list (rows,
// play-on-activate) and one horizontal poster shelf per video library
// (Recently Added, browse-to-detail). A single (section, index) cursor
// covers both: section 0 is Continue Watching, sections 1..N are shelves
// in panel.libraries order.
Item {
  id: page

  required property var panel

  property var onDeckItems: []
  // Continue Watching caps at five rows so Recently Added stays above the
  // fold; the toggle row below expands in place.
  readonly property int cwCap: 5
  property bool cwExpanded: false
  readonly property var cwShown: cwExpanded ? onDeckItems : onDeckItems.slice(0, cwCap)
  readonly property bool cwHasMore: onDeckItems.length > cwCap
  // The toggle behaves as one extra cursor slot at the end of section 0.
  readonly property int cwCursorCount: cwShown.length + (cwHasMore ? 1 : 0)
  property bool onDeckLoading: true
  // A null response is a failed request, not an empty On Deck.
  property bool onDeckFailed: false
  // libraryShelves[i] = { id, title, type } — the shelf LIST, which only
  // changes when the libraries do. Each shelf's contents live apart in
  // shelfData[id] = { items: [], loading: bool, failed: bool }. They used to be one array,
  // so every shelf that finished loading reassigned the Repeater's model,
  // which destroys and rebuilds every shelf block: the column collapsed for a
  // frame and the Flickable clamped the reader's scroll position to it.
  property var libraryShelves: []
  property var shelfData: ({})

  property int cursorSection: 0
  property int cursorIndex: 0

  // Single-highlight rule: the page's own cursor only shows while the panel
  // cursor sits in the "page" region — otherwise the sidebar/search highlight
  // would show alongside ours.
  readonly property bool cursorHere: panel.cursorRegion === "page"

  readonly property int shelfCardWidth: Style.space(120)
  readonly property int shelfCardHeight: Math.round(shelfCardWidth * 3 / 2) + Style.space(40)
  // TV cards carry a third line (episode number under the episode title).
  readonly property int showShelfCardHeight: page.shelfCardHeight + Math.ceil(Style.font.caption * 1.25) + Style.space(2)

  function shelfState(shelf) {
    var st = shelf ? page.shelfData[shelf.id] : null
    return st ? st : { items: [], loading: true, failed: false }
  }

  function isCursorAt(section, index) {
    return page.cursorHere && page.cursorSection === section && page.cursorIndex === index
  }

  function sectionCount() { return 1 + page.libraryShelves.length }

  function itemsFor(section) {
    if (section === 0) return page.cwShown
    return page.shelfState(page.libraryShelves[section - 1]).items
  }

  function clampIndex(section, index) {
    var count = section === 0 ? page.cwCursorCount : page.itemsFor(section).length
    if (count === 0) return 0
    return Math.max(0, Math.min(count - 1, index))
  }

  function clampCursor() {
    if (page.cursorSection >= page.sectionCount()) page.cursorSection = Math.max(0, page.sectionCount() - 1)
    page.cursorIndex = page.clampIndex(page.cursorSection, page.cursorIndex)
  }

  // h/l only ever means something inside a shelf; the Continue Watching
  // list is one column wide, so a horizontal move there is a no-op.
  function moveCursor(dx, dy) {
    if (dx !== 0 && page.cursorSection > 0) {
      page.cursorIndex = page.clampIndex(page.cursorSection, page.cursorIndex + dx)
      page.scrollIntoView()
      return
    }
    if (dy === 0) return

    if (page.cursorSection === 0) {
      var next = page.cursorIndex + dy
      if (next >= 0 && next < page.cwCursorCount) {
        page.cursorIndex = next
        page.scrollIntoView()
        return
      }
      if (dy > 0 && page.sectionCount() > 1) {
        page.cursorSection = 1
        page.cursorIndex = page.clampIndex(1, 0)
        page.scrollIntoView()
      }
      return
    }

    // Inside a shelf, vertical movement always crosses to the adjacent
    // section — a shelf is one row, there is nothing to step through.
    var target = page.cursorSection + (dy > 0 ? 1 : -1)
    if (target < 0 || target >= page.sectionCount()) return
    if (target === 0) page.cursorIndex = Math.max(0, page.cwCursorCount - 1)
    else page.cursorIndex = page.clampIndex(target, page.cursorIndex)
    page.cursorSection = target
    page.scrollIntoView()
  }

  // Collapsing from the bottom of a long list used to leave the highlighted
  // toggle far below the fold; follow it.
  function toggleExpanded() {
    page.cwExpanded = !page.cwExpanded
    page.clampCursor()
    Qt.callLater(page.scrollIntoView)
  }

  function activateCursor() {
    if (page.cursorSection === 0 && page.cwHasMore && page.cursorIndex === page.cwShown.length) {
      page.toggleExpanded()
      return
    }
    var item = page.itemsFor(page.cursorSection)[page.cursorIndex]
    if (!item) return
    if (page.cursorSection === 0) page.panel.playItem(item.ratingKey, item.title)
    else page.openShelfItem(item)
  }

  // TV shelf cards say where they lead (targetKey/targetType): an episode card
  // shows its show, so it opens the show. Movie cards open themselves.
  // An episode card advertises ONE episode ("S2 · E5"), so it also hands the
  // detail page that episode's season and key: the show used to open on the
  // On Deck season instead, nowhere near what the card promised. The header
  // keeps the show title and drops the episode title from the subtitle — the
  // page is the show's, the cursor is what lands on the episode.
  function openShelfItem(item) {
    var key = item.targetKey ? item.targetKey : item.ratingKey
    var type = item.targetType ? item.targetType : item.type
    var args = { ratingKey: key, title: item.title, subtitle: item.caption, type: type }
    if (item.type === "episode" && type === "show") {
      args.subtitle = "TV show"
      args.seasonKey = String(item.seasonKey || "")
      args.episodeKey = String(item.episodeKey || item.ratingKey || "")
    }
    page.panel.navigate("detail", args)
  }

  function bulkMove(delta) {
    if (page.cursorSection > 0) {
      page.cursorIndex = page.clampIndex(page.cursorSection, page.cursorIndex + delta)
      page.scrollIntoView()
      return
    }
    var next = page.cursorIndex + delta
    if (next < 0) { page.cursorIndex = 0 }
    else if (next >= page.cwCursorCount) {
      if (page.sectionCount() > 1) { page.cursorSection = 1; page.cursorIndex = 0 }
      else page.cursorIndex = Math.max(0, page.cwCursorCount - 1)
    } else page.cursorIndex = next
    page.scrollIntoView()
  }
  function pageUp() { page.bulkMove(-5) }
  function pageDown() { page.bulkMove(5) }

  function scrollIntoView() {
    var target = null
    if (page.cursorSection === 0) {
      target = page.cursorIndex === page.cwShown.length ? cwToggle : cwRepeater.itemAt(page.cursorIndex)
    } else {
      var block = shelfRepeater.itemAt(page.cursorSection - 1)
      if (block) {
        block.shelfView.positionViewAtIndex(page.cursorIndex, ListView.Contain)
        target = block
      }
    }
    if (!target) return
    var pos = target.mapToItem(homeFlick.contentItem, 0, 0)
    if (pos.y < homeFlick.contentY) homeFlick.contentY = Math.max(0, pos.y)
    else if (pos.y + target.height > homeFlick.contentY + homeFlick.height)
      homeFlick.contentY = Math.max(0, pos.y + target.height - homeFlick.height)
  }

  // ---- Image-URL handoff: this page resolves every thumbPath at fetch time,
  // at the size its own row/card will actually render. CW rows want landscape
  // 16:9 art; a movie has no landscape thumb of its own, so its wide backdrop
  // (artPath) stands in — episodes' thumbPath is already 16:9.
  function resolveOnDeck(raw) {
    var h = Style.space(56)
    var w = Math.round(h * 16 / 9)
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var it = raw[i]
      var landscape = it.type === "movie" ? it.artPath : it.thumbPath
      out.push(Object.assign({}, it, { thumbPath: page.panel.imageUrl(landscape, w * 2, h * 2) }))
    }
    return out
  }

  function resolveShelf(raw) {
    var w = page.shelfCardWidth
    var h = Math.round(w * 3 / 2)
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var it = raw[i]
      out.push(Object.assign({}, it, { thumbPath: page.panel.imageUrl(it.thumbPath, w * 2, h * 2) }))
    }
    return out
  }

  // Callbacks outlive the page (every navigation rebuilds it); the bump in
  // onDestruction turns a late response into a no-op.
  property int fetchGen: 0

  // ---- cache-first ----
  // Home draws the panel's cached rows (HomeCache.js) at once and the fetches
  // below replace them when they land. Only rows with nothing on screen yet
  // take cached data, so a seed never overwrites a fresh answer.
  function seedFromCache() {
    if (page.onDeckLoading && page.onDeckItems.length === 0) {
      var deck = page.panel.cachedHomeOnDeck()
      if (deck) {
        page.onDeckItems = page.resolveOnDeck(deck)
        page.onDeckLoading = false
      }
    }
    if (page.libraryShelves.length === 0 && (page.panel.libraries || []).length === 0) {
      var list = page.panel.cachedHomeShelfList()
      if (list.length > 0) page.libraryShelves = list.map(function(l) { return { id: l.id, title: l.title, type: l.type } })
    }
    var data = null
    for (var i = 0; i < page.libraryShelves.length; i++) {
      var id = page.libraryShelves[i].id
      if (page.shelfData[id]) continue
      var items = page.panel.cachedHomeShelf(id)
      if (!items) continue
      if (!data) data = Object.assign({}, page.shelfData)
      data[id] = { items: page.resolveShelf(items), loading: false, failed: false }
    }
    if (data) page.shelfData = data
    page.clampCursor()
    page.maybeRestore()
  }

  function fetchOnDeck() {
    // Cached rows stay up while the refresh runs; only an empty list says Loading.
    if (page.onDeckItems.length === 0) page.onDeckLoading = true
    var gen = page.fetchGen
    page.panel.request(Api.onDeckUrl(""), function(doc) {
      if (gen !== page.fetchGen) return
      var raw = []
      try { raw = Api.mapItems(doc) } catch (e) { raw = [] }
      // A failed refresh keeps the rows already on screen.
      page.onDeckFailed = doc === null || doc === undefined
      if (!page.onDeckFailed || page.onDeckItems.length === 0) page.onDeckItems = page.resolveOnDeck(raw)
      page.onDeckLoading = false
      // After the page's own update: the cache signal re-runs seedFromCache.
      if (!page.onDeckFailed) page.panel.cacheHomeOnDeck(raw)
      page.clampCursor()
      page.maybeRestore()
    })
  }

  function fetchShelf(sectionId, type) {
    var isShow = type === "show"
    // TV goes through the grouped hub (one card per show, like stock Plex);
    // a section's own /recentlyAdded would list anonymous episodes.
    var url = isShow ? Api.recentlyAddedHubUrl("", sectionId, 2, 24) : Api.recentlyAddedUrl("", sectionId, 24)
    var gen = page.fetchGen
    page.panel.request(url, function(doc) {
      if (gen !== page.fetchGen) return
      var raw = []
      try { raw = isShow ? Api.mapRecentShows(doc) : Api.mapItems(doc) } catch (e) { raw = [] }
      // Stale response guard: the library may have gone between firing this
      // request and it landing.
      var still = false
      for (var i = 0; i < page.libraryShelves.length; i++) if (page.libraryShelves[i].id === sectionId) still = true
      if (!still) return
      var data = Object.assign({}, page.shelfData)
      var failed = doc === null || doc === undefined
      var prev = data[sectionId]
      // A failed refresh keeps the posters already on screen.
      var items = failed && prev && prev.items.length > 0 ? prev.items : page.resolveShelf(raw)
      data[sectionId] = { items: items, loading: false, failed: failed }
      page.shelfData = data
      if (!failed) page.panel.cacheHomeShelf(sectionId, raw)
      page.clampCursor()
      page.maybeRestore()
    })
  }

  function rebuildShelves() {
    var libs = page.panel.libraries || []
    var shelves = []
    for (var i = 0; i < libs.length; i++) shelves.push({ id: libs[i].id, title: libs[i].title, type: libs[i].type })
    // Only hand the Repeater a new list when the libraries really changed: a
    // refresh re-sends the same sections, and reassigning would rebuild every
    // shelf for nothing (see shelfData above).
    // Before the libraries land, the cached shelf list (seedFromCache) holds
    // the page; don't blank it.
    if (libs.length > 0 && JSON.stringify(shelves) !== JSON.stringify(page.libraryShelves)) page.libraryShelves = shelves
    page.seedFromCache()
    // Shelves already showing keep their posters while the refetch runs.
    for (var j = 0; j < libs.length; j++) page.fetchShelf(libs[j].id, libs[j].type)
    page.clampCursor()
  }

  function reload() {
    page.fetchOnDeck()
    page.rebuildShelves()
  }

  // ---- scroll + cursor memory ----
  // Restored ONCE, after On Deck and every shelf have landed. Restoring at
  // onCompleted ran against placeholder heights: the Flickable clamped the
  // target, and onContentYChanged wrote the clamped value straight back over
  // the real one, so Back landed ~150 px high. Until the restore, nothing is
  // remembered at all. In the meantime every landing re-applies the target
  // as far as the content allows (the placeholders reserve near-final
  // heights, so this is usually already right) — the TV hub takes ~1.4 s,
  // and sitting at the top until then read as "Back lost my place".
  property bool restoreDone: false
  // A wheel during that window is the reader taking over; stop steering.
  property bool userScrolled: false

  function applyScrollTarget() {
    if (page.userScrolled) return
    var maxY = Math.max(0, homeFlick.contentHeight - homeFlick.height)
    homeFlick.contentY = Math.min(maxY, page.panel.scrollFor("home"))
  }

  function maybeRestore() {
    if (page.restoreDone) return
    if (!page.onDeckLoading) page.cwExpanded = page.panel.scrollFor("home:cwExpanded") > 0
    page.applyScrollTarget()
    if (page.onDeckLoading) return
    var libs = page.panel.libraries || []
    if (libs.length > 0 && page.libraryShelves.length === 0) return
    for (var i = 0; i < page.libraryShelves.length; i++)
      if (page.shelfState(page.libraryShelves[i]).loading) return
    // Everything has landed, but the Columns only re-lay out in the next
    // polish pass, and a section swapping placeholder for rows passes
    // through a shorter height on the way — the Flickable clamps contentY
    // there. Settle first, then finish.
    restoreSettle.restart()
  }

  Timer {
    id: restoreSettle
    interval: 60
    onTriggered: page.finishRestore()
  }

  function finishRestore() {
    if (page.restoreDone) return
    page.applyScrollTarget()
    page.restoreDone = true
    page.cursorSection = Math.round(page.panel.scrollFor("home:cursorSection"))
    page.cursorIndex = Math.round(page.panel.scrollFor("home:cursorIndex"))
    page.clampCursor()
    var block = page.cursorSection > 0 ? shelfRepeater.itemAt(page.cursorSection - 1) : null
    if (block) block.shelfView.positionViewAtIndex(page.cursorIndex, ListView.Contain)
  }

  function saveView() {
    if (!page.restoreDone) return
    page.panel.rememberScroll("home", homeFlick.contentY)
    page.panel.rememberScroll("home:cursorSection", page.cursorSection)
    page.panel.rememberScroll("home:cursorIndex", page.cursorIndex)
    page.panel.rememberScroll("home:cwExpanded", page.cwExpanded ? 1 : 0)
  }

  Component.onCompleted: {
    page.seedFromCache()
    page.reload()
    Qt.callLater(page.maybeRestore)
  }
  Component.onDestruction: {
    page.saveView()
    page.fetchGen++
  }

  // Libraries can still be in flight when this page first mounts (root's
  // open() kicks off loadLibraries() but never re-pokes an already-loaded
  // page) — rebuild the shelf list whenever they land.
  Connections {
    target: page.panel
    function onLibrariesChanged() { page.rebuildShelves() }
    // The disk copy can arrive after this page mounted (first open after a
    // shell restart); fill whatever is still empty.
    function onHomeCacheChanged() { page.seedFromCache() }
  }

  Flickable {
    id: homeFlick
    anchors.fill: parent
    contentWidth: width
    contentHeight: mainColumn.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    onContentYChanged: if (page.restoreDone) page.panel.rememberScroll("home", contentY)
    // Re-steer through every relayout until the restore finishes; a
    // transient short layout clamps contentY and this puts it back.
    onContentHeightChanged: if (!page.restoreDone) page.applyScrollTarget()

    // parent: keeps the handler on the viewport rather than inside
    // contentItem, where it scrolls away after the first screen.
    FastScrollHandler {
      parent: homeFlick
      flickable: homeFlick
      onScrolled: if (!page.restoreDone) page.userScrolled = true
    }

    Column {
      id: mainColumn
      width: homeFlick.width
      spacing: Style.space(14)

      Column {
        id: cwSection
        width: parent.width
        spacing: Style.space(6)

        Text {
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          textFormat: Text.PlainText
          text: "CONTINUE WATCHING"
        }

        // A one-line-tall loading section lets the shelves paint near the top
        // and then get shoved off-screen when the rows land. The placeholder
        // reserves the CAPPED list's full height (five rows plus the toggle),
        // so the common case fills in place and nothing below it moves.
        Item {
          width: parent.width
          visible: page.onDeckLoading || page.onDeckItems.length === 0
          height: page.onDeckLoading
            ? page.cwCap * Style.space(56) + page.cwCap * Style.space(4) + cwToggle.implicitHeight
            : Style.space(24)

          Text {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: page.onDeckLoading ? "Loading On Deck…"
              : (page.onDeckFailed ? "Couldn't load On Deck — R to retry"
                : "Nothing in progress. Search to start something.")
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !page.onDeckLoading && page.onDeckItems.length > 0

          Repeater {
            id: cwRepeater
            model: page.cwShown

            MediaRow {
              required property var modelData
              required property int index
              width: mainColumn.width
              itemData: modelData
              artAspect: 16 / 9
              browseOnActivate: false
              selected: page.isCursorAt(0, index)
              cursorOn: page.isCursorAt(0, index)
              onActivated: page.panel.playItem(modelData.ratingKey, modelData.title)
              onHovered: function(on) {
                if (on) { page.cursorSection = 0; page.cursorIndex = index; page.panel.setPanelCursor("page", "") }
              }
            }
          }

          Button {
            id: cwToggle
            visible: page.cwHasMore
            text: page.cwExpanded
              ? "Show fewer"
              : "View all " + page.onDeckItems.length + " · Enter"
            foreground: Color.foreground
            focusable: false
            bordered: false
            hasCursor: page.isCursorAt(0, page.cwShown.length)
            onClicked: page.toggleExpanded()
            onHovered: function(on) {
              if (on) {
                page.cursorSection = 0
                page.cursorIndex = page.cwShown.length
                page.panel.setPanelCursor("page", "")
              }
            }
          }
        }
      }

      Repeater {
        id: shelfRepeater
        model: page.libraryShelves

        Column {
          id: shelfBlock
          required property var modelData
          required property int index
          width: mainColumn.width
          spacing: Style.space(6)
          property alias shelfView: shelfList
          readonly property var contents: page.shelfState(shelfBlock.modelData)
          readonly property bool isShow: shelfBlock.modelData.type === "show"
          readonly property int cardHeight: shelfBlock.isShow ? page.showShelfCardHeight : page.shelfCardHeight

          Item {
            width: parent.width
            height: Math.max(shelfTitle.implicitHeight, shelfArrows.implicitHeight)

            Text {
              id: shelfTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              // A long library name used to run under the arrows.
              width: Math.min(implicitWidth, parent.width - (shelfArrows.visible ? shelfArrows.width + Style.space(8) : 0))
              elide: Text.ElideRight
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              textFormat: Text.PlainText
              text: "RECENTLY ADDED — " + String(shelfBlock.modelData.title || "").toUpperCase()
              // The underline is this link's hover state, so it follows the
              // shared cursor like every other highlight: hovering claims the
              // pointer region (page cursor hides), leaving gives it back.
              font.underline: page.panel.cursorOn("pointer", "shelf-title:" + shelfBlock.modelData.id)

              // The title is the way to the whole list, as on stock Plex: the
              // library page opens on its first sort, "Recently added".
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: page.panel.claimPointer("shelf-title:" + shelfBlock.modelData.id)
                onExited: page.panel.releasePointer("shelf-title:" + shelfBlock.modelData.id)
                onClicked: page.panel.navigate("library", { sectionId: shelfBlock.modelData.id })
              }
            }

            ShelfArrows {
              id: shelfArrows
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              list: shelfList
              panel: page.panel
              key: "shelf:" + shelfBlock.modelData.id
              cardWidth: page.shelfCardWidth
            }
          }

          // Same layout-stability rule as the On Deck placeholder above: an
          // invisible ListView takes no space in a Column, so a loading shelf
          // would collapse and then pop to full height. Reserve it up front.
          Item {
            width: parent.width
            visible: shelfBlock.contents.loading || shelfBlock.contents.items.length === 0
            height: shelfBlock.contents.loading ? shelfBlock.cardHeight : Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              text: shelfBlock.contents.loading
                ? "Loading Recently Added…"
                : (shelfBlock.contents.failed ? "Couldn't load Recently Added — R to retry"
                  : "Nothing added to " + shelfBlock.modelData.title + " yet.")
            }
          }

          ListView {
            id: shelfList
            width: parent.width
            height: shelfBlock.cardHeight
            visible: !shelfBlock.contents.loading && shelfBlock.contents.items.length > 0
            orientation: ListView.Horizontal
            spacing: Style.space(8)
            clip: true
            model: shelfBlock.contents.items

            delegate: PosterCard {
              required property var modelData
              required property int index
              width: page.shelfCardWidth
              itemData: modelData
              cursorOn: page.isCursorAt(shelfBlock.index + 1, index)
              onActivated: page.openShelfItem(modelData)
              onHovered: function(on) {
                if (on) {
                  page.cursorSection = shelfBlock.index + 1
                  page.cursorIndex = index
                  page.panel.setPanelCursor("page", "")
                }
              }
            }
          }
        }
      }
    }
  }
}
