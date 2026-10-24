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
  // libraryShelves[i] = { id, title, type } — the shelf LIST, which only
  // changes when the libraries do. Each shelf's contents live apart in
  // shelfData[id] = { items: [], loading: bool }. They used to be one array,
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
    return st ? st : { items: [], loading: true }
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

  function activateCursor() {
    if (page.cursorSection === 0 && page.cwHasMore && page.cursorIndex === page.cwShown.length) {
      page.cwExpanded = !page.cwExpanded
      page.clampCursor()
      return
    }
    var item = page.itemsFor(page.cursorSection)[page.cursorIndex]
    if (!item) return
    if (page.cursorSection === 0) page.panel.playItem(item.ratingKey, item.title)
    else page.openShelfItem(item)
  }

  // TV shelf cards say where they lead (targetKey/targetType): an episode card
  // shows its show, so it opens the show. Movie cards open themselves.
  function openShelfItem(item) {
    var key = item.targetKey ? item.targetKey : item.ratingKey
    var type = item.targetType ? item.targetType : item.type
    page.panel.navigate("detail", { ratingKey: key, title: item.title, subtitle: item.caption, type: type })
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

  function fetchShelf(sectionId, type) {
    var isShow = type === "show"
    // TV goes through the grouped hub (one card per show, like stock Plex);
    // a section's own /recentlyAdded would list anonymous episodes.
    var url = isShow ? Api.recentlyAddedHubUrl("", sectionId, 2, 24) : Api.recentlyAddedUrl("", sectionId, 24)
    page.panel.request(url, function(doc) {
      var raw = []
      try { raw = isShow ? Api.mapRecentShows(doc) : Api.mapItems(doc) } catch (e) { raw = [] }
      // Stale response guard: the library may have gone between firing this
      // request and it landing.
      var still = false
      for (var i = 0; i < page.libraryShelves.length; i++) if (page.libraryShelves[i].id === sectionId) still = true
      if (!still) return
      var data = Object.assign({}, page.shelfData)
      data[sectionId] = { items: page.resolveShelf(raw), loading: false }
      page.shelfData = data
      page.clampCursor()
    })
  }

  function rebuildShelves() {
    var libs = page.panel.libraries || []
    var shelves = []
    for (var i = 0; i < libs.length; i++) shelves.push({ id: libs[i].id, title: libs[i].title, type: libs[i].type })
    // Only hand the Repeater a new list when the libraries really changed: a
    // refresh re-sends the same sections, and reassigning would rebuild every
    // shelf for nothing (see shelfData above).
    if (JSON.stringify(shelves) !== JSON.stringify(page.libraryShelves)) page.libraryShelves = shelves
    // Shelves already showing keep their posters while the refetch runs.
    for (var j = 0; j < libs.length; j++) page.fetchShelf(libs[j].id, libs[j].type)
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

        // A one-line-tall loading section lets the shelves paint near the top
        // and then get shoved off-screen when the rows land. The placeholder
        // reserves roughly three rows so sections fill in place.
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
          readonly property var contents: page.shelfState(shelfBlock.modelData)
          readonly property bool isShow: shelfBlock.modelData.type === "show"
          readonly property int cardHeight: shelfBlock.isShow ? page.showShelfCardHeight : page.shelfCardHeight

          // Page left/right one shelf-width at a time, the way stock Plex puts
          // chevrons top-right of each row — a mouse has no other way along a
          // shelf without a horizontal wheel.
          function pageShelf(dir) {
            var maxX = Math.max(0, shelfList.contentWidth - shelfList.width)
            var step = Math.max(page.shelfCardWidth, shelfList.width - page.shelfCardWidth)
            shelfScroll.to = Math.max(0, Math.min(maxX, shelfList.contentX + dir * step))
            shelfScroll.restart()
          }

          NumberAnimation {
            id: shelfScroll
            target: shelfList
            property: "contentX"
            duration: 260
            easing.type: Easing.OutCubic
          }

          Item {
            width: parent.width
            height: Math.max(shelfTitle.implicitHeight, shelfArrows.implicitHeight)

            Text {
              id: shelfTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              textFormat: Text.PlainText
              text: "RECENTLY ADDED — " + String(shelfBlock.modelData.title || "").toUpperCase()
              font.underline: titleLink.containsMouse

              // The title is the way to the whole list, as on stock Plex: the
              // library page opens on its first sort, "Recently added".
              MouseArea {
                id: titleLink
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: page.panel.navigate("library", { sectionId: shelfBlock.modelData.id })
              }
            }

            Row {
              id: shelfArrows
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              // Only once the row actually overflows; a short shelf has
              // nowhere to go.
              visible: shelfList.visible && shelfList.contentWidth > shelfList.width + 1

              Button {
                iconText: "󰅁"
                iconSize: Style.font.iconLarge
                foreground: Color.foreground
                focusable: false
                bordered: false
                horizontalPadding: Style.space(5)
                enabled: !shelfList.atXBeginning
                opacity: enabled ? 1 : 0.35
                tooltipText: "Scroll left"
                onClicked: shelfBlock.pageShelf(-1)
              }

              Button {
                iconText: "󰅂"
                iconSize: Style.font.iconLarge
                foreground: Color.foreground
                focusable: false
                bordered: false
                horizontalPadding: Style.space(5)
                enabled: !shelfList.atXEnd
                opacity: enabled ? 1 : 0.35
                tooltipText: "Scroll right"
                onClicked: shelfBlock.pageShelf(1)
              }
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
                : "Nothing added to " + shelfBlock.modelData.title + " yet."
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
