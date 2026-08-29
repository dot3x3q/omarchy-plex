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
  // fold (field request 2026-08-29); the toggle row below expands in place.
  readonly property int cwCap: 5
  property bool cwExpanded: false
  readonly property var cwShown: cwExpanded ? onDeckItems : onDeckItems.slice(0, cwCap)
  readonly property bool cwHasMore: onDeckItems.length > cwCap
  // The toggle behaves as one extra cursor slot at the end of section 0.
  readonly property int cwCursorCount: cwShown.length + (cwHasMore ? 1 : 0)
  property bool onDeckLoading: true
  // libraryShelves[i] = { id, title, items: [], loading: bool }
  property var libraryShelves: []

  property int cursorSection: 0
  property int cursorIndex: 0

  // Single-highlight rule (BUILD-CONTRACT / SettingsPage.qml precedent): the
  // page's own cursor only actually shows while the panel cursor sits in
  // the "page" region — otherwise the sidebar/search highlight would show
  // alongside ours.
  readonly property bool cursorHere: panel.cursorRegion === "page"

  readonly property int shelfCardWidth: Style.space(120)
  readonly property int shelfCardHeight: Math.round(shelfCardWidth * 3 / 2) + Style.space(40)

  function isCursorAt(section, index) {
    return page.cursorHere && page.cursorSection === section && page.cursorIndex === index
  }

  function sectionCount() { return 1 + page.libraryShelves.length }

  function itemsFor(section) {
    if (section === 0) return page.cwShown
    var shelf = page.libraryShelves[section - 1]
    return shelf ? shelf.items : []
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

  function activateCursor() {
    if (page.cursorSection === 0 && page.cwHasMore && page.cursorIndex === page.cwShown.length) {
      page.cwExpanded = !page.cwExpanded
      page.clampCursor()
      return
    }
    var item = page.itemsFor(page.cursorSection)[page.cursorIndex]
    if (!item) return
    if (page.cursorSection === 0) page.panel.playItem(item.ratingKey, item.title)
    else page.panel.navigate("detail", { ratingKey: item.ratingKey, title: item.title, subtitle: item.caption, type: item.type })
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

  // ---- Image-URL handoff: this page resolves every thumbPath at fetch
  // time, at the size its own row/card will actually render (contract). CW
  // rows want landscape 16:9 art; a movie has no landscape thumb of its
  // own, so its wide backdrop (artPath) stands in — episodes' thumbPath is
  // already 16:9 (PLEX-API.md "Image path rules").
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

  function fetchOnDeck() {
    page.onDeckLoading = true
    page.panel.request(Api.onDeckUrl(""), function(doc) {
      var raw = []
      try { raw = Api.mapItems(doc) } catch (e) { raw = [] }
      page.onDeckItems = page.resolveOnDeck(raw)
      page.onDeckLoading = false
      page.clampCursor()
    })
  }

  function fetchShelf(idx, sectionId) {
    page.panel.request(Api.recentlyAddedUrl("", sectionId, 24), function(doc) {
      var raw = []
      try { raw = Api.mapItems(doc) } catch (e) { raw = [] }
      var shelves = page.libraryShelves.slice()
      // Stale response guard: panel.libraries may have changed shape (or
      // reordered) between firing this request and it landing.
      if (idx >= shelves.length || shelves[idx].id !== sectionId) return
      shelves[idx] = Object.assign({}, shelves[idx], { items: page.resolveShelf(raw), loading: false })
      page.libraryShelves = shelves
      page.clampCursor()
    })
  }

  function rebuildShelves() {
    var libs = page.panel.libraries || []
    var shelves = []
    for (var i = 0; i < libs.length; i++) shelves.push({ id: libs[i].id, title: libs[i].title, items: [], loading: true })
    page.libraryShelves = shelves
    for (var j = 0; j < libs.length; j++) page.fetchShelf(j, libs[j].id)
    page.clampCursor()
  }

  function reload() {
    page.fetchOnDeck()
    page.rebuildShelves()
  }

  Component.onCompleted: page.reload()

  // Libraries can still be in flight when this page first mounts (root's
  // open() kicks off loadLibraries() but never re-pokes an already-loaded
  // page) — rebuild the shelf list whenever they land.
  Connections {
    target: page.panel
    function onLibrariesChanged() { page.rebuildShelves() }
  }

  Flickable {
    id: homeFlick
    anchors.fill: parent
    contentWidth: width
    contentHeight: mainColumn.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Component.onCompleted: homeFlick.contentY = page.panel.scrollFor("home")
    onContentYChanged: page.panel.rememberScroll("home", contentY)
    Component.onDestruction: page.panel.rememberScroll("home", homeFlick.contentY)

    FastScrollHandler { flickable: homeFlick }

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

        // Field report 2026-08-28: while On Deck loaded, this section was one
        // line tall, so the shelves painted near the top and then got shoved
        // off-screen when the rows landed — reading as the page "changing".
        // The placeholder reserves roughly three rows so sections fill in
        // place instead of reflowing.
        Item {
          width: parent.width
          visible: page.onDeckLoading || page.onDeckItems.length === 0
          height: page.onDeckLoading ? Style.space(180) : Style.space(24)

          Text {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: page.onDeckLoading ? "Loading On Deck…" : "Nothing in progress. Search to start something."
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
            onClicked: { page.cwExpanded = !page.cwExpanded; page.clampCursor() }
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

          Text {
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            textFormat: Text.PlainText
            text: "RECENTLY ADDED — " + String(shelfBlock.modelData.title || "").toUpperCase()
          }

          // Same layout-stability rule as the On Deck placeholder above: an
          // invisible ListView takes no space in a Column, so a loading shelf
          // would collapse and then pop to full height. Reserve it up front.
          Item {
            width: parent.width
            visible: shelfBlock.modelData.loading || shelfBlock.modelData.items.length === 0
            height: shelfBlock.modelData.loading ? page.shelfCardHeight : Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              text: shelfBlock.modelData.loading
                ? "Loading Recently Added…"
                : "Nothing added to " + shelfBlock.modelData.title + " yet."
            }
          }

          ListView {
            id: shelfList
            width: parent.width
            height: page.shelfCardHeight
            visible: !shelfBlock.modelData.loading && shelfBlock.modelData.items.length > 0
            orientation: ListView.Horizontal
            spacing: Style.space(8)
            clip: true
            model: shelfBlock.modelData.items

            delegate: PosterCard {
              required property var modelData
              required property int index
              width: page.shelfCardWidth
              itemData: modelData
              cursorOn: page.isCursorAt(shelfBlock.index + 1, index)
              onActivated: page.panel.navigate("detail", { ratingKey: modelData.ratingKey, title: modelData.title, subtitle: modelData.caption, type: modelData.type })
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
