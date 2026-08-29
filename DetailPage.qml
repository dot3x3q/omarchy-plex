// Delegates below reach the page's cursor state by id; Bound makes that an
// explicit capture instead of a dynamic lookup qmllint cannot verify.
pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "Api.js" as Api

// Detail hero for a movie OR a show (DESIGN.md "Detail pages for both").
// The hero is the one sanctioned divergence from the flat-surface kit norm:
// the item's wide backdrop art under a heavy flat scrim, calibrated so
// theme-colored text still reads on light themes (Spotify's watermark
// treatment is the reference point). Shows get a season picker plus an
// episode list below; movies get the hero alone.
Item {
  id: page

  required property var panel

  // pageParams always carries enough to draw the hero immediately; the full
  // metadata request only fills in the parts we could not know yet.
  readonly property var params: page.panel.pageParams ? page.panel.pageParams : ({})
  // Plex rating keys are numeric, and this one is pasted straight into a
  // request path — strip anything that could smuggle in a second query param.
  readonly property string ratingKey: String(page.params.ratingKey || "").replace(/[^A-Za-z0-9]/g, "")
  readonly property string paramTitle: String(page.params.title || "")
  readonly property string paramType: String(page.params.type || "")

  property string loadedKey: ""
  property var detail: null
  property bool detailFailed: false
  property var onDeck: null
  property var seasons: []
  property var episodes: []
  property string seasonKey: ""
  property bool episodesLoading: false
  property int seasonCount: 0
  property int episodeCount: 0
  property int durationMs: 0
  // Callbacks outlive the navigation that started them; a stale response must
  // never overwrite the page we are looking at now.
  property int loadGen: 0
  property int seasonGen: 0
  property bool restorePending: false

  // "Show-shaped": anything whose children resolve to playable episodes. TV
  // libraries hand back SEASON objects from recentlyAdded and search, and a
  // season routed through the movie path had no episode list and a Play that
  // always failed — its own ratingKey has no Media/Part (review finding).
  // A season's children are episodes, which the flat-show branch of
  // loadSeasons already renders; the season picker simply stays empty.
  readonly property bool isShow: {
    var t = page.detail ? String(page.detail.type) : page.paramType
    return t === "show" || t === "season"
  }
  readonly property string scrollKey: "detail:" + page.ratingKey

  readonly property real heroHeight: Style.space(150)
  readonly property real heroInset: Style.space(10)
  readonly property real posterHeight: page.heroHeight - page.heroInset * 2
  readonly property real posterWidth: page.posterHeight * 2 / 3

  // Cursor rows, top to bottom. Movies stop at rowPlay.
  readonly property int rowPlay: 0
  readonly property int rowSeasons: 1
  readonly property int rowEpisodes: 2
  property int cursorRow: 0
  property int cursorSeason: 0
  property int cursorEpisode: 0

  // Our highlight only exists while the panel cursor is in the page region —
  // otherwise it would coexist with the sidebar's and break single-highlight.
  readonly property bool cursorHere: page.panel.cursorRegion === "page"

  // ---- data ----

  function load() {
    page.loadedKey = page.ratingKey
    page.loadGen += 1
    page.detail = null
    page.detailFailed = false
    page.onDeck = null
    page.seasons = []
    page.episodes = []
    page.seasonKey = ""
    page.seasonCount = 0
    page.episodeCount = 0
    page.durationMs = 0
    page.cursorRow = page.rowPlay
    page.cursorSeason = 0
    page.cursorEpisode = 0
    page.restorePending = true
    if (page.ratingKey === "") return

    var gen = page.loadGen
    // Image sizes are chosen HERE, at fetch time, per the image-URL handoff:
    // components bind Image.source to the path they are handed and know
    // nothing about auth or sizing.
    var backW = Math.round(Math.max(Style.space(400), page.width) * 2)
    var backH = Math.round(page.heroHeight * 2)
    var postW = Math.round(page.posterWidth * 2)
    var postH = Math.round(page.posterHeight * 2)

    // includeOnDeck=1 is what makes "Play" mean something on a show: the
    // server picks the resume-or-next-unwatched episode itself (verified live
    // — it is present even on a show nobody has started, pointing at S1E1).
    // Harmless on a movie, which simply comes back without the block, so this
    // does not need pageParams.type to be trustworthy.
    page.panel.request(Api.metadataUrl("", page.ratingKey) + "?includeOnDeck=1", function(doc) {
      if (gen !== page.loadGen) return
      var item = Api.mapDetail(doc)
      if (!item) { page.detailFailed = true; return }
      var raw = doc && doc.MediaContainer && doc.MediaContainer.Metadata
        ? doc.MediaContainer.Metadata[0] : null
      // mapDetail is deliberately type-agnostic, so the show-only counts and
      // the OnDeck block are read off the raw container here rather than
      // widening a mapper every other page would pay for.
      page.seasonCount = raw ? Number(raw.childCount) || 0 : 0
      page.episodeCount = raw ? Number(raw.leafCount) || 0 : 0
      page.durationMs = raw ? Number(raw.duration) || 0 : 0
      page.onDeck = page.onDeckFrom(raw)
      page.detail = Object.assign({}, item, {
        artUrl: page.panel.imageUrl(item.artPath, backW, backH),
        posterUrl: page.panel.imageUrl(item.thumbPath, postW, postH)
      })
      if (String(item.type) === "show") page.loadSeasons(gen)
    })
  }

  function reload() { page.load() }

  // Plex hands OnDeck back as a single object, not the Metadata ARRAY every
  // other endpoint uses — accept both rather than trusting that forever.
  function onDeckFrom(raw) {
    var od = raw && raw.OnDeck ? raw.OnDeck.Metadata : null
    if (Array.isArray(od)) od = od.length > 0 ? od[0] : null
    if (!od || !od.ratingKey) return null
    var dur = Number(od.duration) || 0
    var off = Number(od.viewOffset) || 0
    return {
      ratingKey: String(od.ratingKey).replace(/[^A-Za-z0-9]/g, ""),
      title: String(od.title || ""),
      seasonKey: String(od.parentRatingKey || ""),
      label: "S" + (od.parentIndex === undefined || od.parentIndex === null ? "?" : od.parentIndex)
        + "E" + (od.index === undefined || od.index === null ? "?" : od.index),
      progress: dur > 0 ? Math.max(0, Math.min(1, off / dur)) : 0,
      remainingMs: Math.max(0, dur - off)
    }
  }

  function loadSeasons(gen) {
    page.episodesLoading = true
    page.panel.request(Api.childrenUrl("", page.ratingKey), function(doc) {
      if (gen !== page.loadGen) return
      var list = Api.mapChildren(doc)
      var found = []
      for (var i = 0; i < list.length; i++)
        if (String(list[i].type) === "season") found.push(list[i])
      page.seasons = found
      if (found.length === 0) {
        // A show flat enough to hand back episodes directly still has to work.
        page.episodes = page.decorateEpisodes(doc)
        page.episodesLoading = false
        page.restoreScroll()
        return
      }
      // Open on the season the server says you are in the middle of; the
      // first season only when nothing identifies one.
      var want = page.onDeck ? String(page.onDeck.seasonKey) : ""
      var at = 0
      for (var j = 0; j < found.length; j++)
        if (String(found[j].ratingKey) === want) { at = j; break }
      page.cursorSeason = at
      page.selectSeason(String(found[at].ratingKey))
    })
  }

  function selectSeason(key) {
    var clean = String(key || "").replace(/[^A-Za-z0-9]/g, "")
    if (clean === "") return
    page.seasonKey = clean
    page.episodes = []
    page.episodesLoading = true
    page.cursorEpisode = 0
    var gen = page.loadGen
    page.seasonGen += 1
    var sgen = page.seasonGen
    page.panel.request(Api.childrenUrl("", clean), function(doc) {
      if (gen !== page.loadGen || sgen !== page.seasonGen) return
      page.episodes = page.decorateEpisodes(doc)
      page.episodesLoading = false
      page.restoreScroll()
    })
  }

  // Row-ready episodes: the mapper's `sub` is the show name (right for a
  // search hit, redundant under a show's own hero), so it is replaced with
  // the position/length/watched line this list actually wants.
  function decorateEpisodes(doc) {
    var items = Api.mapChildren(doc)
    var meta = doc && doc.MediaContainer && doc.MediaContainer.Metadata
      ? doc.MediaContainer.Metadata : []
    var byKey = ({})
    for (var i = 0; i < meta.length; i++)
      if (meta[i] && meta[i].ratingKey !== undefined) byKey[String(meta[i].ratingKey)] = meta[i]
    var thumbW = Math.round(Style.space(160))
    var thumbH = Math.round(Style.space(90))
    var out = []
    for (var j = 0; j < items.length; j++) {
      var it = items[j]
      if (String(it.type) !== "episode") continue
      var raw = byKey[String(it.ratingKey)] || ({})
      var bits = []
      var epNo = Number(raw.index) || 0
      if (epNo > 0) bits.push("E" + epNo)
      if (it.durationText) bits.push(String(it.durationText))
      if (Number(it.progress) > 0)
        bits.push(Api.durationText((Number(raw.duration) || 0) * (1 - Number(it.progress))) + " left")
      else if (!it.unwatched) bits.push("Watched")
      out.push(Object.assign({}, it, {
        sub: bits.join(" · "),
        thumbPath: page.panel.imageUrl(it.thumbPath, thumbW, thumbH)
      }))
    }
    return out
  }

  function restoreScroll() {
    if (!page.restorePending) return
    page.restorePending = false
    episodeList.contentY = page.panel.scrollFor(page.scrollKey)
  }

  function saveScroll() {
    if (page.ratingKey !== "") page.panel.rememberScroll(page.scrollKey, episodeList.contentY)
  }

  // ---- hero text ----

  function metaLine() {
    var d = page.detail
    var parts = []
    if (page.isShow) {
      if (d && d.year) parts.push(String(d.year))
      var seasons = page.seasonCount > 0 ? page.seasonCount : page.seasons.length
      if (seasons > 0) parts.push(seasons + (seasons === 1 ? " season" : " seasons"))
      if (page.episodeCount > 0)
        parts.push(page.episodeCount + (page.episodeCount === 1 ? " episode" : " episodes"))
      var left = d ? Number(d.unwatched) || 0 : 0
      if (left > 0) parts.push(left + " unwatched")
    } else {
      if (d && d.year) parts.push(String(d.year))
      if (d && d.contentRating) parts.push(String(d.contentRating))
      if (d && d.rating) parts.push("󰓎 " + Number(d.rating).toFixed(1))
      if (d && d.durationText) parts.push(String(d.durationText))
    }
    return parts.join(" · ")
  }

  // What Play means: a movie plays itself; a show plays the episode the
  // server put on deck, falling back to the first episode of whatever season
  // is loaded when the show has no on-deck entry at all.
  function playTarget() {
    if (!page.isShow) {
      if (page.ratingKey === "") return null
      return {
        ratingKey: page.ratingKey,
        title: page.detail ? String(page.detail.title) : page.paramTitle,
        label: "",
        progress: page.detail ? Number(page.detail.progress) || 0 : 0,
        remainingMs: page.durationMs * (1 - (page.detail ? Number(page.detail.progress) || 0 : 0))
      }
    }
    if (page.onDeck) return page.onDeck
    if (page.episodes.length > 0) {
      var first = page.episodes[0]
      return {
        ratingKey: String(first.ratingKey),
        title: String(first.title),
        label: String(first.caption || ""),
        progress: Number(first.progress) || 0,
        remainingMs: 0
      }
    }
    return null
  }

  function playLabel() {
    var t = page.playTarget()
    if (t && Number(t.progress) > 0 && Number(t.remainingMs) > 0)
      return "Resume · " + Api.durationText(t.remainingMs) + " left"
    if (t && Number(t.progress) > 0) return "Resume"
    return "Play"
  }

  function playTooltip() {
    var t = page.playTarget()
    if (!t) return "Play · Enter"
    if (page.isShow) return "Play " + (t.label ? t.label + " · " : "") + t.title + " · Enter"
    return page.playLabel() + " · Enter"
  }

  function playNow() {
    var t = page.playTarget()
    if (t) page.panel.playItem(t.ratingKey, t.title)
  }

  // ---- keyboard ----

  function lastRow() {
    if (!page.isShow) return page.rowPlay
    if (page.episodes.length > 0) return page.rowEpisodes
    if (page.seasons.length > 0) return page.rowSeasons
    return page.rowPlay
  }

  function claim(row) {
    page.cursorRow = row
    page.panel.setPanelCursor("page", "")
  }

  function moveCursor(dx, dy) {
    if (dx !== 0) {
      if (page.cursorRow !== page.rowSeasons || page.seasons.length === 0) return
      var n = page.seasons.length
      page.cursorSeason = ((page.cursorSeason + dx) % n + n) % n
      // Moving across the picker IS choosing — the episode list below is the
      // whole point of the row, and a two-step select would just be friction.
      page.selectSeason(String(page.seasons[page.cursorSeason].ratingKey))
      return
    }
    if (dy === 0) return
    if (page.cursorRow === page.rowEpisodes) {
      var next = page.cursorEpisode + dy
      if (next < 0) {
        page.cursorRow = page.seasons.length > 0 ? page.rowSeasons : page.rowPlay
        return
      }
      page.cursorEpisode = Math.min(page.episodes.length - 1, next)
      return
    }
    var target = Math.max(page.rowPlay, Math.min(page.lastRow(), page.cursorRow + dy))
    if (target === page.rowEpisodes && page.episodes.length === 0) return
    page.cursorRow = target
  }

  function activateCursor() {
    if (page.cursorRow === page.rowPlay) { page.playNow(); return }
    if (page.cursorRow === page.rowSeasons) {
      if (page.seasons.length === 0) return
      page.selectSeason(String(page.seasons[page.cursorSeason].ratingKey))
      if (page.episodes.length > 0) page.cursorRow = page.rowEpisodes
      return
    }
    if (page.episodes.length === 0) return
    var ep = page.episodes[page.cursorEpisode]
    if (ep) page.panel.playItem(String(ep.ratingKey), String(ep.title))
  }

  function pageStep(dir) {
    if (page.cursorRow !== page.rowEpisodes || page.episodes.length === 0) {
      page.moveCursor(0, dir)
      return
    }
    var span = Math.max(1, Math.floor(episodeList.height / Math.max(1, Style.space(56))) - 1)
    page.cursorEpisode = Math.max(0, Math.min(page.episodes.length - 1, page.cursorEpisode + dir * span))
  }

  function pageUp() { page.pageStep(-1) }
  function pageDown() { page.pageStep(1) }

  Component.onCompleted: page.load()
  Component.onDestruction: page.saveScroll()
  // Drilling from one detail page to another reuses this instance (the Loader
  // only sees currentPage), so the params change is the reload trigger.
  onRatingKeyChanged: if (page.ratingKey !== page.loadedKey) page.load()
  onCursorEpisodeChanged: episodeList.positionViewAtIndex(page.cursorEpisode, ListView.Contain)
  onCursorSeasonChanged: seasonList.positionViewAtIndex(page.cursorSeason, ListView.Contain)

  // ---- hero ----

  BorderSurface {
    id: hero
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: page.heroHeight
    radius: Style.cornerRadius
    color: Style.normalFillFor(Color.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
    clip: true

    Image {
      id: backdrop
      anchors.fill: parent
      anchors.margins: Style.space(2)
      source: page.detail ? String(page.detail.artUrl || "") : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      // No art is not a failure state: the hero falls back to the same card
      // fill every other surface uses, which reads as deliberate.
      visible: status === Image.Ready
    }

    // Flat, not a gradient. 0.82 is where theme foreground text still reads
    // over a bright backdrop on Omarchy's light themes while the art stays
    // legible as texture rather than turning into a grey plate.
    Rectangle {
      anchors.fill: backdrop
      visible: backdrop.visible
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)
    }

    BorderSurface {
      id: posterWell
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: page.heroInset
      anchors.topMargin: page.heroInset
      width: page.posterWidth
      height: page.posterHeight
      radius: Style.spacing.labelGap
      color: Style.selectedFillFor(Color.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
      clip: true

      Image {
        id: poster
        anchors.fill: parent
        anchors.margins: Style.space(2)
        source: page.detail ? String(page.detail.posterUrl || "") : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: poster.status !== Image.Ready
        text: page.isShow ? "󰦔" : "󰎁"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge
      }
    }

    Column {
      id: heroText
      anchors.left: posterWell.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: page.heroInset
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)

      Text {
        width: parent.width
        text: page.detail ? String(page.detail.title || page.paramTitle) : page.paramTitle
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: page.metaLine()
        visible: text !== ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        // Loading and empty are the same muted line with different sentences
        // (DESIGN.md: no spinners, no skeletons).
        text: page.detail ? String(page.detail.summary || "No synopsis for this one.")
          : (page.detailFailed ? "Could not load details." : "Loading details…")
        color: page.detail && page.detail.summary ? Color.foreground : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Button {
          id: playButton
          anchors.verticalCenter: parent.verticalCenter
          text: page.playLabel()
          iconText: "󰐊"
          bordered: true
          focusable: false
          foreground: Color.foreground
          accent: Color.accent
          enabled: page.playTarget() !== null
          hasCursor: page.cursorHere && page.cursorRow === page.rowPlay
          tooltipText: page.playTooltip()
          onClicked: page.playNow()
          onHovered: function(on) { if (on) page.claim(page.rowPlay) }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - playButton.width - parent.spacing)
          text: page.detail && page.detail.genres ? page.detail.genres.join(" · ") : ""
          visible: text !== ""
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }
    }
  }

  // ---- seasons (shows only) ----

  ListView {
    id: seasonList
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: hero.bottom
    anchors.topMargin: visible ? Style.space(10) : 0
    height: visible ? Style.space(30) : 0
    visible: page.isShow && page.seasons.length > 0
    orientation: ListView.Horizontal
    spacing: Style.space(6)
    clip: true
    model: page.seasons
    boundsBehavior: Flickable.StopAtBounds

    delegate: Button {
      required property int index
      required property var modelData

      height: seasonList.height
      text: String(modelData.title || "Season")
      bordered: true
      focusable: false
      foreground: Color.foreground
      accent: Color.accent
      selected: page.seasonKey === String(modelData.ratingKey)
      hasCursor: page.cursorHere && page.cursorRow === page.rowSeasons && page.cursorSeason === index
      tooltipText: (String(modelData.caption || "") !== ""
        ? String(modelData.caption) + " · " : "") + "←/→ switch seasons"
      onClicked: {
        page.cursorSeason = index
        page.claim(page.rowSeasons)
        page.selectSeason(String(modelData.ratingKey))
      }
      onHovered: function(on) {
        if (!on) return
        page.cursorSeason = index
        page.claim(page.rowSeasons)
      }
    }

    FastScrollHandler {
      flickable: seasonList
    }
  }

  // ---- episodes (shows only) ----

  ListView {
    id: episodeList
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: seasonList.visible ? seasonList.bottom : hero.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    visible: page.isShow
    clip: true
    spacing: Style.space(3)
    reuseItems: true
    model: page.episodes
    boundsBehavior: Flickable.StopAtBounds
    onMovementEnded: page.saveScroll()

    delegate: MediaRow {
      required property int index
      required property var modelData

      itemData: modelData
      artAspect: 16 / 9
      // Episodes are leaves: activating one plays it, it never "opens".
      browseOnActivate: false
      selected: page.cursorHere && page.cursorRow === page.rowEpisodes && page.cursorEpisode === index
      onActivated: page.panel.playItem(String(modelData.ratingKey), String(modelData.title))
      onHovered: function(on) {
        if (!on) return
        page.cursorEpisode = index
        page.claim(page.rowEpisodes)
      }
    }

    FastScrollHandler {
      flickable: episodeList
      onScrolled: page.saveScroll()
    }

    Text {
      anchors.centerIn: parent
      visible: page.episodes.length === 0
      text: page.episodesLoading ? "Loading episodes…" : "No episodes in this season."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      textFormat: Text.PlainText
    }
  }
}
