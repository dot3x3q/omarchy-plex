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
  // PlexPanel.showPage() builds a fresh page for every navigation, so these
  // are this page's own params for its whole life.
  readonly property var params: page.panel.pageParams ? page.panel.pageParams : ({})
  // Plex rating keys are numeric, and this one is pasted straight into a
  // request path — strip anything that could smuggle in a second query param.
  readonly property string ratingKey: String(page.params.ratingKey || "").replace(/[^A-Za-z0-9]/g, "")
  readonly property string paramTitle: String(page.params.title || "")
  readonly property string paramType: String(page.params.type || "")
  // A TV-shelf episode card opens the show AT that episode: its season wins
  // over the On Deck one, and the cursor lands on the episode itself.
  readonly property string paramSeasonKey: String(page.params.seasonKey || "").replace(/[^A-Za-z0-9]/g, "")
  readonly property string paramEpisodeKey: String(page.params.episodeKey || "").replace(/[^A-Za-z0-9]/g, "")

  property string loadedKey: ""
  property var detail: null
  property bool detailFailed: false
  property var onDeck: null
  property var seasons: []
  property var episodes: []
  property string seasonKey: ""
  property bool episodesLoading: false
  property bool episodesFailed: false
  property int seasonCount: 0
  property int episodeCount: 0
  property int durationMs: 0
  // Season pages: the show they belong to. Live season metadata carries an
  // empty summary, so the hero borrows the show's.
  property string parentTitle: ""
  property string parentSummary: ""
  // The first real season (index > 0; Specials sorts first) and, when no On
  // Deck block exists, the episode Play falls back to (see playTarget).
  property string defaultSeasonKey: ""
  property var fallbackEpisode: null
  // Episode the cursor should land on once its season's list arrives.
  property string pendingEpisodeKey: ""
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
  readonly property bool isSeason: (page.detail ? String(page.detail.type) : page.paramType) === "season"
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

  // Cursor rows. Shows: play, seasons, episodes, cast (the cast sits in the
  // episode list's footer, one step past the last episode). Movies: play,
  // cast, extras, related.
  readonly property int rowPlay: 0
  readonly property int rowSeasons: 1
  readonly property int rowEpisodes: 2
  readonly property int rowExtras: 3
  readonly property int rowRelated: 4
  readonly property int rowCast: 5
  property int cursorRow: 0
  property int cursorSeason: 0
  property int cursorEpisode: 0
  property int cursorExtra: 0
  property int cursorCast: 0
  // Play is where the cursor rests by default, so a mouse that passed over it
  // and left would otherwise leave it lit like a stuck hover. Leaving drops
  // the highlight; ANY keyboard input aimed at the page, or the cursor
  // re-entering the page region, brings it back (see revealCursor). Enter
  // used to play while the highlight was hidden.
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
  onCursorHereChanged: if (page.cursorHere) page.playUnhovered = false

  // ---- data ----

  // /children paged. One unpaged body for a long-running show's season can
  // pass 256 items (Api's MAX_ITEMS cap, so the list silently truncated) or
  // 4 MiB (the request pool's cap, so it failed as null). This builds the
  // same URL shape the data batch's Api.childrenUrl(server, key, { start,
  // size }) will. TODO(consolidate): switch to that once it lands.
  readonly property int childPageSize: 256
  readonly property int childPageLimit: 16

  function childrenPageUrl(key, start) {
    return "/library/metadata/" + encodeURIComponent(String(key)) + "/children"
      + "?X-Plex-Container-Start=" + start + "&X-Plex-Container-Size=" + page.childPageSize
  }

  // Calls done(docs, failed) with every page's raw doc, in order. `alive`
  // is re-checked on every hop so a page left (or a season switched) stops
  // paging at once. A failure after page one keeps what already arrived.
  function fetchChildren(key, alive, done) {
    var docs = []
    var seen = 0
    function step(start) {
      page.panel.request(page.childrenPageUrl(key, start), function(doc) {
        if (!alive()) return
        if (doc === null || doc === undefined) { done(docs, true); return }
        var mc = doc.MediaContainer || ({})
        var got = Array.isArray(mc.Metadata) ? mc.Metadata.length : 0
        docs.push(doc)
        seen += got
        var total = Number(mc.totalSize)
        var more = isNaN(total) || mc.totalSize === undefined ? got >= page.childPageSize : seen < total
        if (more && got > 0 && docs.length < page.childPageLimit) step(start + page.childPageSize)
        else done(docs, false)
      })
    }
    step(0)
  }

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
    page.episodesFailed = false
    page.seasonCount = 0
    page.episodeCount = 0
    page.durationMs = 0
    page.parentTitle = ""
    page.parentSummary = ""
    page.defaultSeasonKey = ""
    page.fallbackEpisode = null
    page.pendingEpisodeKey = page.paramEpisodeKey
    page.cursorRow = page.rowPlay
    page.cursorSeason = 0
    page.cursorEpisode = 0
    page.cursorExtra = 0
    page.cursorCast = 0
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
    // server picks the resume-or-next-unwatched episode itself. It is NOT
    // always there (live: "1883" comes back without it), so playTarget has a
    // fallback. Harmless on a movie, which simply comes back without the
    // block, so this does not need pageParams.type to be trustworthy.
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
      if (t === "season" && raw) page.loadParent(gen, raw)
      if (t === "show" || t === "season") page.loadSeasons(gen)
      else page.loadRelated(gen)
    })
  }

  function reload() { page.load() }

  // A season page names its show and borrows the show's synopsis: live
  // season metadata has an empty summary, so the hero said just "Season 1"
  // and "No synopsis for this one." (TODO(consolidate): a parent-fields
  // mapper in Api.js.)
  function loadParent(gen, raw) {
    page.parentTitle = String(raw.parentTitle || "")
    if (String(raw.summary || "") !== "") return
    var parentKey = String(raw.parentRatingKey || "").replace(/[^A-Za-z0-9]/g, "")
    if (parentKey === "") return
    page.panel.request(Api.metadataUrl("", parentKey), function(doc) {
      if (gen !== page.loadGen) return
      var p = doc && doc.MediaContainer && doc.MediaContainer.Metadata ? doc.MediaContainer.Metadata[0] : null
      if (p) page.parentSummary = String(p.summary || "")
    })
  }

  function loadRelated(gen) {
    page.panel.request(Api.relatedUrl("", page.ratingKey), function(doc) {
      if (gen !== page.loadGen) return
      var list = []
      try { list = Api.mapRelated(doc) } catch (e) { list = [] }
      page.related = page.resolveImages(list, "thumbPath", page.relatedWidth, page.relatedWidth * 3 / 2)
      // The movie page is at full height once Related has landed (or
      // failed), so this is when its scroll can be restored.
      Qt.callLater(page.restoreScroll)
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
    page.fetchChildren(page.ratingKey, function() { return gen === page.loadGen }, function(docs, failed) {
      var found = []
      var indexOf = ({})
      for (var d = 0; d < docs.length; d++) {
        var list = Api.mapChildren(docs[d])
        var meta = docs[d].MediaContainer && docs[d].MediaContainer.Metadata ? docs[d].MediaContainer.Metadata : []
        for (var m = 0; m < meta.length; m++)
          if (meta[m] && meta[m].ratingKey !== undefined) indexOf[String(meta[m].ratingKey)] = Number(meta[m].index)
        for (var i = 0; i < list.length; i++)
          if (String(list[i].type) === "season") found.push(list[i])
      }
      page.seasons = found
      if (found.length === 0) {
        // A show flat enough to hand back episodes directly still has to work
        // (and so does a season page, whose children ARE episodes).
        page.episodes = page.decorateAll(docs)
        page.episodesFailed = failed && page.episodes.length === 0
        page.episodesLoading = false
        page.landEpisodes(false)
        return
      }
      // Specials (index 0) sort first. Without an On Deck block the show
      // used to open on — and Play started — Season 0's first special.
      var first = 0
      for (var f = 0; f < found.length; f++)
        if (indexOf[String(found[f].ratingKey)] > 0) { first = f; break }
      page.defaultSeasonKey = String(found[first].ratingKey)
      // Which season to open on: the one the TV-shelf card advertised, then
      // the one this page was showing when you left it, then the one the
      // server says you are in the middle of, then the first real season.
      var at = -1
      var want = [page.paramSeasonKey,
        page.restorePending ? page.rememberedSeasonKey() : "",
        page.onDeck ? String(page.onDeck.seasonKey) : ""]
      for (var w = 0; w < want.length && at < 0; w++) {
        if (want[w] === "") continue
        for (var j = 0; j < found.length; j++)
          if (String(found[j].ratingKey) === want[w]) { at = j; break }
      }
      if (at < 0) at = first
      page.cursorSeason = at
      page.selectSeason(String(found[at].ratingKey), false)
      // Play's fallback lives in the first real season; when another season
      // is the one on screen, fetch the fallback's first page separately.
      if (!page.onDeck && at !== first) page.loadFallback(gen, page.defaultSeasonKey)
    })
  }

  function loadFallback(gen, key) {
    page.panel.request(page.childrenPageUrl(key, 0), function(doc) {
      if (gen !== page.loadGen || doc === null) return
      page.fallbackEpisode = page.firstUnwatched(page.decorateEpisodes(doc))
    })
  }

  // fromEnter: Enter on the season picker drills into the list once it lands.
  // selectSeason empties the episodes first, so checking the length right
  // after calling it was always false and Enter never drilled in.
  function selectSeason(key, fromEnter) {
    var clean = String(key || "").replace(/[^A-Za-z0-9]/g, "")
    if (clean === "") return
    if (clean === page.seasonKey && !page.episodesLoading && page.episodes.length > 0) {
      if (fromEnter) page.cursorRow = page.rowEpisodes
      return
    }
    page.seasonKey = clean
    page.episodes = []
    page.episodesLoading = true
    page.episodesFailed = false
    page.cursorEpisode = 0
    var gen = page.loadGen
    page.seasonGen += 1
    var sgen = page.seasonGen
    page.fetchChildren(clean, function() { return gen === page.loadGen && sgen === page.seasonGen }, function(docs, failed) {
      page.episodes = page.decorateAll(docs)
      page.episodesFailed = failed && page.episodes.length === 0
      page.episodesLoading = false
      // Play's no-On-Deck fallback stays valid after switching seasons.
      if (!page.onDeck && clean === page.defaultSeasonKey && !page.fallbackEpisode)
        page.fallbackEpisode = page.firstUnwatched(page.episodes)
      page.landEpisodes(fromEnter)
    })
  }

  // An episode list has arrived: put the cursor where it was asked to go
  // (the advertised episode, or the list itself after Enter), then restore
  // the remembered scroll on the first landing only.
  function landEpisodes(fromEnter) {
    if (page.pendingEpisodeKey !== "") {
      for (var i = 0; i < page.episodes.length; i++) {
        if (String(page.episodes[i].ratingKey) === page.pendingEpisodeKey) {
          page.cursorEpisode = i
          page.cursorRow = page.rowEpisodes
          page.pendingEpisodeKey = ""
          page.restorePending = false
          Qt.callLater(function() { episodeList.positionViewAtIndex(page.cursorEpisode, ListView.Center) })
          return
        }
      }
      page.pendingEpisodeKey = ""
    }
    if (fromEnter && page.episodes.length > 0) page.cursorRow = page.rowEpisodes
    page.restoreScroll()
  }

  function decorateAll(docs) {
    var out = []
    for (var d = 0; d < docs.length; d++) out = out.concat(page.decorateEpisodes(docs[d]))
    return out
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

  // ---- scroll + cursor memory ----
  // Banked per item: the list scroll (episode list or movie shelves), the
  // cursor row and its position in that row, and the season on screen. The
  // cursor used to reset to Play after Back, wherever the scroll landed.
  function rememberedSeasonKey() {
    var at = Math.round(page.panel.scrollFor(page.scrollKey + ":season")) - 1
    return at >= 0 && at < page.seasons.length ? String(page.seasons[at].ratingKey) : ""
  }

  function restoreScroll() {
    if (!page.restorePending) return
    page.restorePending = false
    var key = page.scrollKey
    if (page.isShow) episodeList.contentY = page.panel.scrollFor(key)
    else movieFlick.contentY = Math.min(Math.max(0, movieFlick.contentHeight - movieFlick.height), page.panel.scrollFor(key))
    var row = Math.round(page.panel.scrollFor(key + ":row"))
    var at = Math.round(page.panel.scrollFor(key + ":at"))
    if (row === page.rowEpisodes && page.episodes.length > 0) {
      page.cursorEpisode = Math.min(page.episodes.length - 1, at)
      page.cursorRow = row
    } else if (row === page.rowExtras && page.extras.length > 0) {
      page.cursorExtra = Math.min(page.extras.length - 1, at)
      page.cursorRow = row
    } else if (row === page.rowRelated && page.related.length > 0) {
      page.cursorRelated = Math.min(page.related.length - 1, at)
      page.cursorRow = row
    } else if (row === page.rowCast && page.cast.length > 0) {
      page.cursorCast = Math.min(page.cast.length - 1, at)
      page.cursorRow = row
    } else if (row === page.rowSeasons && page.seasons.length > 0) {
      page.cursorRow = row
    }
  }

  function saveScroll() {
    if (page.ratingKey === "" || page.restorePending) return
    var key = page.scrollKey
    page.panel.rememberScroll(key, page.isShow ? episodeList.contentY : movieFlick.contentY)
    page.panel.rememberScroll(key + ":row", page.cursorRow)
    page.panel.rememberScroll(key + ":at", page.cursorRow === page.rowEpisodes ? page.cursorEpisode
      : (page.cursorRow === page.rowExtras ? page.cursorExtra
        : (page.cursorRow === page.rowRelated ? page.cursorRelated
          : (page.cursorRow === page.rowCast ? page.cursorCast : 0))))
    // +1 so "nothing remembered" (0) stays distinct from the first season.
    if (page.seasons.length > 0) page.panel.rememberScroll(key + ":season", page.cursorSeason + 1)
  }

  // ---- hero text ----

  // "<Show> — Season 1" on a season page; the item's own title otherwise.
  function heroTitle() {
    var own = page.detail ? String(page.detail.title || page.paramTitle) : page.paramTitle
    if (page.isSeason && page.parentTitle !== "") return page.parentTitle + " — " + own
    return own
  }

  function heroSummary() {
    if (!page.detail) return page.detailFailed ? "Couldn't load details — R to retry" : "Loading details…"
    var own = String(page.detail.summary || "")
    if (own !== "") return own
    if (page.parentSummary !== "") return page.parentSummary
    return "No synopsis for this one."
  }

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

  // Resume-or-next: the first episode not yet finished, else the first.
  function firstUnwatched(list) {
    for (var i = 0; i < list.length; i++)
      if (list[i].unwatched || Number(list[i].progress) > 0) return page.asTarget(list[i])
    return list.length > 0 ? page.asTarget(list[0]) : null
  }

  function asTarget(ep) {
    return {
      ratingKey: String(ep.ratingKey),
      title: String(ep.title),
      label: String(ep.caption || ""),
      progress: Number(ep.progress) || 0,
      remainingMs: 0
    }
  }

  // What Play means: a movie plays itself; a show plays the episode the
  // server put on deck. With no On Deck block (it can be absent — live:
  // "1883"), the first unfinished episode of the first REAL season; it used
  // to be episode 1 of whatever loaded first, which was Season 0/Specials.
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
    if (page.fallbackEpisode) return page.fallbackEpisode
    // A season page, a flat show, or the default season is the one on screen.
    if (page.seasons.length === 0 || page.seasonKey === page.defaultSeasonKey)
      return page.firstUnwatched(page.episodes)
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
    if (page.cast.length > 0) rows.push(page.rowCast)
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
      else if (page.cursorRow === page.rowCast)
        page.cursorCast = Math.max(0, Math.min(page.cast.length - 1, page.cursorCast + dx))
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
  // view inside its shelf. Play sits in the hero, which now scrolls with the
  // shelves, so Play means "back to the top".
  function scrollMovieRow() {
    var target = page.cursorRow === page.rowExtras ? extrasBlock
      : (page.cursorRow === page.rowRelated ? relatedBlock
        : (page.cursorRow === page.rowCast ? movieCast : null))
    if (page.cursorRow === page.rowExtras) extrasList.positionViewAtIndex(page.cursorExtra, ListView.Contain)
    if (page.cursorRow === page.rowRelated) relatedList.positionViewAtIndex(page.cursorRelated, ListView.Contain)
    if (page.cursorRow === page.rowCast) movieCast.showIndex(page.cursorCast)
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

  // Any keyboard input aimed at the page shows the cursor again.
  function revealCursor() {
    var hidden = page.playUnhovered && page.cursorRow === page.rowPlay
    page.playUnhovered = false
    return hidden
  }

  function moveCursor(dx, dy) {
    page.revealCursor()
    if (!page.isShow) { page.moveMovieCursor(dx, dy); return }
    if (page.cursorRow === page.rowCast) {
      // Show pages: the cast sits in the episode list's footer.
      if (dx !== 0) {
        page.cursorCast = Math.max(0, Math.min(page.cast.length - 1, page.cursorCast + dx))
        if (showCastShelf()) showCastShelf().showIndex(page.cursorCast)
        return
      }
      if (dy < 0) {
        page.cursorRow = page.episodes.length > 0 ? page.rowEpisodes : page.rowPlay
        if (page.episodes.length > 0) episodeList.positionViewAtIndex(page.cursorEpisode, ListView.Contain)
      }
      return
    }
    if (dx !== 0) {
      if (page.cursorRow !== page.rowSeasons || page.seasons.length === 0) return
      var n = page.seasons.length
      page.cursorSeason = ((page.cursorSeason + dx) % n + n) % n
      // Moving across the picker IS choosing — the episode list below is the
      // whole point of the row, and a two-step select would just be friction.
      page.selectSeason(String(page.seasons[page.cursorSeason].ratingKey), false)
      return
    }
    if (dy === 0) return
    if (page.cursorRow === page.rowEpisodes) {
      var next = page.cursorEpisode + dy
      if (next < 0) {
        page.cursorRow = page.seasons.length > 0 ? page.rowSeasons : page.rowPlay
        return
      }
      if (next >= page.episodes.length && page.cast.length > 0) {
        // Past the last episode: the cast row in the footer.
        page.cursorRow = page.rowCast
        episodeList.positionViewAtEnd()
        return
      }
      page.cursorEpisode = Math.min(page.episodes.length - 1, next)
      return
    }
    var target = Math.max(page.rowPlay, Math.min(page.lastRow(), page.cursorRow + dy))
    if (target === page.rowEpisodes && page.episodes.length === 0) return
    page.cursorRow = target
  }

  function showCastShelf() {
    var f = episodeList.footerItem
    return f && f.children.length > 0 ? f.children[0] : null
  }

  function activateCursor() {
    // Enter on a hidden Play only brings the highlight back; it used to start
    // playback on a target nobody could see.
    if (page.revealCursor()) return
    if (page.cursorRow === page.rowPlay) { page.playNow(); return }
    if (page.cursorRow === page.rowExtras) { page.playExtra(page.extras[page.cursorExtra]); return }
    if (page.cursorRow === page.rowRelated) { page.openRelated(page.related[page.cursorRelated]); return }
    // Cast cards have nowhere to go yet (no person pages); the row exists so
    // the cast can be walked with the keyboard at all.
    if (page.cursorRow === page.rowCast) return
    if (page.cursorRow === page.rowSeasons) {
      if (page.seasons.length === 0) return
      page.selectSeason(String(page.seasons[page.cursorSeason].ratingKey), true)
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
    page.revealCursor()
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
  // Defensive: showPage rebuilds the page for a new ratingKey, but if params
  // ever change in place, bank this item's position before reloading.
  onRatingKeyChanged: if (page.ratingKey !== page.loadedKey) {
    if (page.loadedKey !== "") page.panel.rememberScroll("detail:" + page.loadedKey, page.isShow ? episodeList.contentY : movieFlick.contentY)
    page.load()
  }
  onCursorEpisodeChanged: if (page.cursorRow === page.rowEpisodes) episodeList.positionViewAtIndex(page.cursorEpisode, ListView.Contain)
  onCursorSeasonChanged: seasonList.positionViewAtIndex(page.cursorSeason, ListView.Contain)

  // Cast row, shared by the movie page's shelves and the show page's episode
  // list footer. An inline component cannot see this file's ids, so what it
  // shows comes in through properties.
  component CastShelf: Column {
    id: castShelf
    required property var people
    required property real cardWidth
    required property var panel
    // Which card holds the page cursor; -1 when the cast row does not.
    property int cursorIndex: -1
    signal cardHovered(int index)
    width: parent.width
    spacing: Style.space(6)
    visible: castShelf.people.length > 0

    function showIndex(i) { castList.positionViewAtIndex(i, ListView.Contain) }

    Item {
      width: parent.width
      height: Math.max(castTitle.implicitHeight, castArrows.implicitHeight)

      Text {
        id: castTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
        text: "CAST & CREW"
      }

      ShelfArrows {
        id: castArrows
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        list: castList
        panel: castShelf.panel
        key: "detail:cast"
        cardWidth: castShelf.cardWidth
      }
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
        required property int index
        width: castShelf.cardWidth
        height: castList.height

        // Same single-highlight fill as the other shelves: the page cursor,
        // never this card's own hover.
        BorderSurface {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: castShelf.cursorIndex === castCard.index ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
        }

        HoverHandler {
          onHoveredChanged: if (hovered) castShelf.cardHovered(castCard.index)
        }

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
            textFormat: Text.PlainText
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
  // On a movie the hero scrolls away with the shelves under it: a fixed 256 px
  // hero left a short window (< ~390 px) with negative shelf height and the
  // minibar over Play. The hero is drawn in this clipping frame rather than
  // inside movieFlick's Column so the show layout (seasons and episodes
  // anchored under a fixed hero) stays untouched; movieColumn reserves the
  // same height with a spacer, and the frame shrinks as the content scrolls.
  // z above the Flickable so the hero's own controls get their clicks; the
  // wheel still falls through to movieFlick's handler underneath.
  Item {
    id: heroFrame
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: page.isShow ? page.heroHeight : Math.max(0, page.heroHeight - movieFlick.contentY)
    clip: true
    z: 1

    BorderSurface {
      id: hero
      anchors.left: parent.left
      anchors.right: parent.right
      y: page.isShow ? 0 : -movieFlick.contentY
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
          textFormat: Text.PlainText
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
          text: page.heroTitle()
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
          text: page.heroSummary()
          color: page.detail && (page.detail.summary || page.parentSummary !== "") ? Color.foreground : Color.muted
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
  }

  // ---- seasons (shows only) ----

  ListView {
    id: seasonList
    anchors.left: parent.left
    anchors.right: seasonArrows.visible ? seasonArrows.left : parent.right
    anchors.rightMargin: seasonArrows.visible ? Style.space(6) : 0
    anchors.top: heroFrame.bottom
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
        page.selectSeason(String(modelData.ratingKey), false)
      }
      onHovered: function(on) {
        if (!on) return
        page.cursorSeason = index
        page.claim(page.rowSeasons)
      }
    }

    // parent: on every handler here — declared bare, it lands in contentItem
    // and scrolls away with the content after the first screen.
    // Nothing scrolls vertically here, so the plain wheel walks the seasons;
    // it used to do nothing at all (verified offscreen: contentX stayed 0).
    FastScrollHandler {
      parent: seasonList
      flickable: seasonList
      horizontal: true
      verticalWheel: true
    }
  }

  ShelfArrows {
    id: seasonArrows
    anchors.right: parent.right
    anchors.verticalCenter: seasonList.verticalCenter
    list: seasonList
    panel: page.panel
    key: "detail:seasons"
    cardWidth: Style.space(90)
  }

  // ---- episodes (shows only) ----

  ListView {
    id: episodeList
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: seasonList.visible ? seasonList.bottom : heroFrame.bottom
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
        panel: page.panel
        cursorIndex: page.cursorHere && page.cursorRow === page.rowCast ? page.cursorCast : -1
        onCardHovered: function(index) { page.cursorCast = index; page.claim(page.rowCast) }
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
      text: page.episodesLoading ? "Loading episodes…"
        : (page.episodesFailed ? "Couldn't load episodes — R to retry" : "No episodes in this season.")
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
    anchors.top: parent.top
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

      // Reserves the hero's height; the hero itself is drawn by heroFrame.
      Item {
        width: parent.width
        height: page.heroHeight - movieColumn.spacing + Style.space(10)
      }

      CastShelf {
        id: movieCast
        width: parent.width
        people: page.cast
        cardWidth: page.castWidth
        panel: page.panel
        cursorIndex: page.cursorHere && page.cursorRow === page.rowCast ? page.cursorCast : -1
        onCardHovered: function(index) { page.cursorCast = index; page.claim(page.rowCast) }
      }

      Column {
        id: extrasBlock
        width: parent.width
        spacing: Style.space(6)
        visible: page.extras.length > 0

        Item {
          width: parent.width
          height: Math.max(extrasTitle.implicitHeight, extrasArrows.implicitHeight)

          Text {
            id: extrasTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            textFormat: Text.PlainText
            text: "EXTRAS"
          }

          ShelfArrows {
            id: extrasArrows
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            list: extrasList
            panel: page.panel
            key: "detail:extras"
            cardWidth: page.extraWidth
          }
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
                textFormat: Text.PlainText
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

        Item {
          width: parent.width
          height: Math.max(relatedTitle.implicitHeight, relatedArrows.implicitHeight)

          Text {
            id: relatedTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            textFormat: Text.PlainText
            text: "RELATED MOVIES"
          }

          ShelfArrows {
            id: relatedArrows
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            list: relatedList
            panel: page.panel
            key: "detail:related"
            cardWidth: page.relatedWidth
          }
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
