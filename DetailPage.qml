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
// theme-colored text still reads on light themes. Shows get a season picker
// plus an episode list below; movies get the hero alone.
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
  // season has no Media/Part of its own, so routing one through the movie path
  // gives it no episode list and a Play that always fails. A season's children
  // are episodes, which the flat-show branch of loadSeasons already renders;
  // the season picker simply stays empty.
  readonly property bool isShow: {
    var t = page.detail ? String(page.detail.type) : page.paramType
    return t === "show" || t === "season"
  }
  readonly property string scrollKey: "detail:" + page.ratingKey

  // Movies get the taller, stock-Plex-style hero (director, ratings, video and
  // audio lines); shows keep the compact one so the episode list stays big.
  // Secondary hero text. The theme's `muted` is tuned for flat surfaces and
  // went hard to read over the scrimmed backdrop; foreground at 80% keeps
  // the hierarchy and still reads.
  readonly property color heroDim: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.8)
  readonly property real heroHeight: page.isShow ? Style.space(176) : Style.space(256)
  readonly property real heroInset: Style.space(10)
  readonly property real posterHeight: page.heroHeight - page.heroInset * 2
  readonly property real posterWidth: page.posterHeight * 2 / 3

  // Cursor rows, top to bottom. Shows: play, seasons, episodes. Movies: play,
  // extras, related (cast is read-only, so the cursor skips it).
  readonly property int rowPlay: 0
  readonly property int rowSeasons: 1
  readonly property int rowEpisodes: 2
  readonly property int rowExtras: 3
  readonly property int rowRelated: 4
  property int cursorRow: 0
  property int cursorSeason: 0
  property int cursorEpisode: 0
  property int cursorExtra: 0
  // Play is where the cursor rests by default, so a mouse that passed over it
  // and left would otherwise leave it lit like a stuck hover. Leaving drops
  // the highlight; any keyboard move brings it back.
  property bool playUnhovered: false
  property int cursorRelated: 0

  // Movie-page shelves (Api.mapDetail), image URLs resolved at fetch time.
  readonly property var cast: page.detail && page.detail.cast ? page.detail.cast : []
  readonly property var extras: page.detail && page.detail.extras ? page.detail.extras : []
  // Fetched separately after the page draws (Api.relatedUrl: it is slow).
  property var related: []
  readonly property real castWidth: Style.space(96)
  readonly property real extraWidth: Style.space(200)
  readonly property real relatedWidth: Style.space(110)

  // Our highlight only exists while the panel cursor is in the page region —
  // otherwise it would coexist with the sidebar's and break single-highlight.
  readonly property bool cursorHere: page.panel.cursorRegion === "page"

  // ---- data ----

  function load() {
    page.loadedKey = page.ratingKey
    page.loadGen += 1
    page.playUnhovered = false
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
    page.cursorExtra = 0
    page.cursorRelated = 0
    page.related = []
    movieFlick.contentY = 0
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
    // server picks the resume-or-next-unwatched episode itself, and the block
    // is present even on a show nobody has started, where it points at S1E1.
    // Harmless on a movie, which simply comes back without the block, so this
    // does not need pageParams.type to be trustworthy.
    // includeExtras/includeRelated ride along for the movie page's shelves.
    page.panel.request(Api.detailUrl("", page.ratingKey), function(doc) {
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
        posterUrl: page.panel.imageUrl(item.thumbPath, postW, postH),
        cast: page.resolveImages(item.cast, "photoPath", page.castWidth, page.castWidth * 1.25),
        extras: page.resolveImages(item.extras, "thumbPath", page.extraWidth, page.extraWidth * 9 / 16)
      })
      // A season's children are its episodes, which loadSeasons' flat branch
      // already renders — this used to say `=== "show"` only, so a season
      // page (Home's TV shelf opens them) drew the hero over an empty list.
      var t = String(item.type)
      if (t === "show" || t === "season") page.loadSeasons(gen)
      else page.loadRelated(gen)
    })
  }

  function reload() { page.load() }

  function loadRelated(gen) {
    page.panel.request(Api.relatedUrl("", page.ratingKey), function(doc) {
      if (gen !== page.loadGen) return
      var list = []
      try { list = Api.mapRelated(doc) } catch (e) { list = [] }
      page.related = page.resolveImages(list, "thumbPath", page.relatedWidth, page.relatedWidth * 3 / 2)
    })
  }

  function resolveImages(list, field, w, h) {
    var out = []
    var src = list || []
    for (var i = 0; i < src.length; i++) {
      var patch = {}
      var path = String(src[i][field] || "")
      // Cast photos are absolute public URLs (metadata-static.plex.tv,
      // image.tmdb.org) and need neither the server nor the token. Through the
      // transcoder they carried X-Plex-Token, and QQuickImage writes the full
      // URL of any image that fails into the shell log — dead cast photos are
      // common, so the token was landing in the log (seen 2026-10-23). Only
      // https is taken as-is; anything else stays on the server path.
      patch[field] = path.indexOf("https://") === 0 ? path
        : page.panel.imageUrl(path, Math.round(w * 2), Math.round(h * 2))
      out.push(Object.assign({}, src[i], patch))
    }
    return out
  }

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

  // Movie rows in order, skipping shelves that came back empty.
  function movieRows() {
    var rows = [page.rowPlay]
    if (page.extras.length > 0) rows.push(page.rowExtras)
    if (page.related.length > 0) rows.push(page.rowRelated)
    return rows
  }

  function moveMovieCursor(dx, dy) {
    if (dx !== 0) {
      if (page.cursorRow === page.rowExtras)
        page.cursorExtra = Math.max(0, Math.min(page.extras.length - 1, page.cursorExtra + dx))
      else if (page.cursorRow === page.rowRelated)
        page.cursorRelated = Math.max(0, Math.min(page.related.length - 1, page.cursorRelated + dx))
      page.scrollMovieRow()
      return
    }
    var rows = page.movieRows()
    var at = Math.max(0, rows.indexOf(page.cursorRow))
    var next = Math.max(0, Math.min(rows.length - 1, at + (dy > 0 ? 1 : -1)))
    page.cursorRow = rows[next]
    page.scrollMovieRow()
  }

  // Keep the cursor's shelf on screen in the movie Flickable, and the card in
  // view inside its shelf.
  function scrollMovieRow() {
    var target = page.cursorRow === page.rowExtras ? extrasBlock
      : (page.cursorRow === page.rowRelated ? relatedBlock : null)
    if (page.cursorRow === page.rowExtras) extrasList.positionViewAtIndex(page.cursorExtra, ListView.Contain)
    if (page.cursorRow === page.rowRelated) relatedList.positionViewAtIndex(page.cursorRelated, ListView.Contain)
    if (!target) { movieFlick.contentY = 0; return }
    var y = target.mapToItem(movieFlick.contentItem, 0, 0).y
    if (y < movieFlick.contentY) movieFlick.contentY = Math.max(0, y)
    else if (y + target.height > movieFlick.contentY + movieFlick.height)
      movieFlick.contentY = Math.max(0, Math.min(movieFlick.contentHeight - movieFlick.height, y + target.height - movieFlick.height))
  }

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
    page.playUnhovered = false
    if (!page.isShow) { page.moveMovieCursor(dx, dy); return }
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
    if (page.cursorRow === page.rowExtras) { page.playExtra(page.extras[page.cursorExtra]); return }
    if (page.cursorRow === page.rowRelated) { page.openRelated(page.related[page.cursorRelated]); return }
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

  function playExtra(x) {
    if (x) page.panel.playItem(String(x.ratingKey), String(x.title))
  }

  function openRelated(it) {
    if (it) page.panel.navigate("detail", { ratingKey: it.ratingKey, title: it.title, subtitle: it.caption, type: it.type })
  }

  function pageStep(dir) {
    if (!page.isShow) {
      movieFlick.contentY = Math.max(0, Math.min(Math.max(0, movieFlick.contentHeight - movieFlick.height),
        movieFlick.contentY + dir * movieFlick.height * 0.8))
      return
    }
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
  // Every navigation now rebuilds the page (PlexPanel showPage), so a
  // response for a page already left is routine. Bumping the generations on
  // the way out makes those callbacks return at their gen check instead of
  // calling into a torn-down context.
  Component.onDestruction: {
    page.saveScroll()
    page.loadGen += 1
    page.seasonGen += 1
  }
  // Drilling from one detail page to another reuses this instance (the Loader
  // only sees currentPage), so the params change is the reload trigger.
  onRatingKeyChanged: if (page.ratingKey !== page.loadedKey) page.load()
  onCursorEpisodeChanged: episodeList.positionViewAtIndex(page.cursorEpisode, ListView.Contain)
  onCursorSeasonChanged: seasonList.positionViewAtIndex(page.cursorSeason, ListView.Contain)

  // Cast row, shared by the movie page's shelves and the show page's episode
  // list footer. An inline component cannot see this file's ids, so what it
  // shows comes in through properties.
  component CastShelf: Column {
    id: castShelf
    required property var people
    required property real cardWidth
    width: parent.width
    spacing: Style.space(6)
    visible: castShelf.people.length > 0

    Text {
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      textFormat: Text.PlainText
      text: "CAST & CREW"
    }

    ListView {
      id: castList
      width: parent.width
      height: castShelf.cardWidth * 1.25 + Style.space(44)
      orientation: ListView.Horizontal
      spacing: Style.space(10)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: castShelf.people

      delegate: Item {
        id: castCard
        required property var modelData
        width: castShelf.cardWidth
        height: castList.height

        BorderSurface {
          id: photoWell
          width: parent.width
          height: castShelf.cardWidth * 1.25
          radius: Style.spacing.labelGap
          color: Style.selectedFillFor(Color.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
          clip: true

          Image {
            id: photo
            anchors.fill: parent
            anchors.margins: Style.space(2)
            source: String(castCard.modelData.photoPath || "")
            // Loaded straight from the public host at full size; decode small.
            sourceSize.width: castShelf.cardWidth * 2
            sourceSize.height: castShelf.cardWidth * 2.5
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: photo.status !== Image.Ready
            text: "󰀄"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
          }
        }

        Column {
          anchors.top: photoWell.bottom
          anchors.topMargin: Style.space(4)
          width: parent.width
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: String(castCard.modelData.name || "")
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            text: String(castCard.modelData.role || "")
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
  }

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

      // Movie-only lines, the stock Plex hero: who made it, then how it rates.
      Text {
        width: parent.width
        text: !page.isShow && page.detail && page.detail.directors && page.detail.directors.length > 0
          ? "Directed by " + page.detail.directors.join(", ") : ""
        visible: text !== ""
        color: page.heroDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: page.metaLine()
        visible: text !== ""
        color: page.heroDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: page.detail && page.detail.ratings ? page.detail.ratings.join("   ") : ""
        visible: text !== ""
        color: Color.foreground
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
        maximumLineCount: page.isShow ? 3 : 5
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Row {
        width: parent.width
        // Breathing room between the synopsis and the Play button.
        topPadding: Style.space(6)
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
          hasCursor: page.cursorHere && page.cursorRow === page.rowPlay && !page.playUnhovered
          tooltipText: page.playTooltip()
          onClicked: page.playNow()
          onHovered: function(on) {
            page.playUnhovered = !on
            if (on) page.claim(page.rowPlay)
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - playButton.width - parent.spacing)
          text: page.detail && page.detail.genres ? page.detail.genres.join(" · ") : ""
          visible: text !== ""
          color: page.heroDim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      // What the file is: Plex's short stream titles ("4K DoVi/HDR10 (HEVC
      // Main 10)", "English (DTS-HD MA 5.1)"). The pickers in theater still
      // own switching tracks; this is the at-a-glance read.
      Text {
        width: parent.width
        text: {
          var d = page.detail
          if (page.isShow || !d) return ""
          var bits = []
          if (d.videoText) bits.push("Video  " + d.videoText)
          if (d.audioText) bits.push("Audio  " + d.audioText)
          if (Number(d.subtitleCount) > 0) bits.push("Subtitles  " + d.subtitleCount)
          return bits.join("   ·   ")
        }
        visible: text !== ""
        color: page.heroDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
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

    // parent: on every handler here — declared bare, it lands in contentItem
    // and scrolls away with the content after the first screen.
    FastScrollHandler {
      parent: seasonList
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

    // Cast sits under the last episode rather than above the seasons: the
    // episode list is what a show page is for, so it keeps the space and the
    // cast is one scroll past the end.
    footer: Item {
      width: episodeList.width
      height: page.cast.length > 0 && page.episodes.length > 0 ? showCast.height + Style.space(16) : 0
      visible: height > 0

      CastShelf {
        id: showCast
        y: Style.space(16)
        width: parent.width
        people: page.cast
        cardWidth: page.castWidth
      }
    }

    FastScrollHandler {
      parent: episodeList
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

  // ---- movie shelves: cast, extras, related ----
  // Below the fixed hero, one vertical Flickable; each shelf is a horizontal
  // ListView like the home page's. Same no-spinner rule: a shelf with nothing
  // in it is simply absent.
  Flickable {
    id: movieFlick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: hero.bottom
    anchors.topMargin: Style.space(10)
    anchors.bottom: parent.bottom
    visible: !page.isShow
    contentWidth: width
    contentHeight: movieColumn.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    FastScrollHandler { parent: movieFlick; flickable: movieFlick }

    Column {
      id: movieColumn
      width: movieFlick.width
      spacing: Style.space(14)

      CastShelf {
        width: parent.width
        people: page.cast
        cardWidth: page.castWidth
      }

      Column {
        id: extrasBlock
        width: parent.width
        spacing: Style.space(6)
        visible: page.extras.length > 0

        Text {
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          textFormat: Text.PlainText
          text: "EXTRAS"
        }

        ListView {
          id: extrasList
          width: parent.width
          height: page.extraWidth * 9 / 16 + Style.space(48)
          orientation: ListView.Horizontal
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: page.extras

          delegate: Item {
            id: extraCard
            required property var modelData
            required property int index
            width: page.extraWidth
            height: extrasList.height
            readonly property bool cursorOn: page.cursorHere && page.cursorRow === page.rowExtras && page.cursorExtra === extraCard.index

            // Same single-highlight fill model as PosterCard: the page cursor,
            // never this card's own hover.
            BorderSurface {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: extraCard.cursorOn ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
            }

            HoverHandler {
              onHoveredChanged: if (hovered) { page.cursorExtra = extraCard.index; page.claim(page.rowExtras) }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: page.playExtra(extraCard.modelData)
            }

            BorderSurface {
              id: extraWell
              width: parent.width
              height: page.extraWidth * 9 / 16
              radius: Style.spacing.labelGap
              color: Style.selectedFillFor(Color.foreground, Color.accent)
              borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
              clip: true

              Image {
                id: extraArt
                anchors.fill: parent
                anchors.margins: Style.space(2)
                source: String(extraCard.modelData.thumbPath || "")
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                visible: status === Image.Ready
              }

              Text {
                anchors.centerIn: parent
                text: "󰐊"
                color: extraArt.visible ? Color.foreground : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.iconLarge
              }
            }

            Column {
              anchors.top: extraWell.bottom
              anchors.topMargin: Style.space(4)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: String(extraCard.modelData.title || "")
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                width: parent.width
                text: String(extraCard.modelData.kind || "")
                  + (extraCard.modelData.durationText ? " · " + extraCard.modelData.durationText : "")
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }
          }
        }
      }

      Column {
        id: relatedBlock
        width: parent.width
        spacing: Style.space(6)
        visible: page.related.length > 0

        Text {
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          textFormat: Text.PlainText
          text: "RELATED MOVIES"
        }

        ListView {
          id: relatedList
          width: parent.width
          height: Math.round(page.relatedWidth * 3 / 2) + Style.space(40)
          orientation: ListView.Horizontal
          spacing: Style.space(8)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: page.related

          delegate: PosterCard {
            id: relatedCard
            required property var modelData
            required property int index
            width: page.relatedWidth
            itemData: relatedCard.modelData
            cursorOn: page.cursorHere && page.cursorRow === page.rowRelated && page.cursorRelated === relatedCard.index
            onActivated: page.openRelated(relatedCard.modelData)
            onHovered: function(on) {
              if (on) { page.cursorRelated = relatedCard.index; page.claim(page.rowRelated) }
            }
          }
        }
      }
    }
  }
}
