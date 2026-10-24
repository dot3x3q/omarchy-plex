// Plex REST layer: URL builders + JSON response mappers. No I/O, no QML
// imports — panel.request() (PlexPanel.qml) owns the curl process pool and
// hands parsed JSON back here. Plain function declarations, no module syntax,
// same convention as Model.js: this file loads as a QML script resource and
// under node:vm for unit tests.
//
// The mappers are written against real Plex Media Server responses; the shapes
// they cope with are not always the obvious ones. docs/PLEX-API.md carries
// sanitized samples.

var MAX_ITEMS = 256
var MAX_FIELD = 256
var MAX_KEY = 96

function cap(value, limit) {
  var s = String(value === undefined || value === null ? "" : value)
  return s.length > limit ? s.slice(0, limit) : s
}

// Server-derived identifiers that travel in URL paths and query strings.
// Plex keys are numeric in practice; stripping to alphanumerics at the
// mapping boundary means every downstream consumer (playItem, timeline,
// URL builders) inherits the invariant instead of re-implementing it.
function keyOf(value) {
  return cap(value, MAX_KEY).replace(/[^A-Za-z0-9]/g, "")
}

// Content scope is movies + TV only (DESIGN.md) — music lives in the
// Spotify app's lane. /search proved to mix in album/artist/track/photo
// hits for a generic query, so every mapper that walks a Metadata array
// filters through this allowlist rather than trusting the endpoint.
var ITEM_TYPES = { movie: true, show: true, season: true, episode: true }

// ---- URL builders ----

function sectionsUrl(server) {
  return server + "/library/sections"
}

function onDeckUrl(server) {
  return server + "/library/onDeck"
}

// recentlyAdded pagination: the X-Plex-Container-Start/Size names work
// identically as headers or as query params. Query params are used because
// Api.js builds plain URLs, and per-call headers would need extra plumbing in
// panel.request() for no gain.
function recentlyAddedUrl(server, sectionId, size) {
  var url = server + "/library/sections/" + encodeURIComponent(String(sectionId)) + "/recentlyAdded"
  return size ? url + "?X-Plex-Container-Start=0&X-Plex-Container-Size=" + size : url
}

// The hub stock Plex draws its "Recently Added in TV Shows" row from. Where
// the section's /recentlyAdded lists bare EPISODES (a row of anonymous
// screenshots titled "Episode 2"), this one groups them the way a person
// reads it: one entry per show, as a show (a whole new show or a big batch),
// a season (several new episodes of one season) or a single episode. Probed
// live 2026-10-23; type=2 is Plex's show metadata type.
function recentlyAddedHubUrl(server, sectionId, type, size) {
  return server + "/hubs/home/recentlyAdded?type=" + encodeURIComponent(String(type)) +
    "&sectionID=" + encodeURIComponent(String(sectionId)) +
    "&X-Plex-Container-Start=0&X-Plex-Container-Size=" + size
}

// opts: { sort, start, size }. "addedAt:desc", "titleSort" and "year:desc" all
// sort server-side, so no client-side re-sort is needed. titleSort strips
// leading articles ("The 'Burbs" sorts as "'Burbs"), which is why a plain
// title-string sort looks "wrong" next to Plex's own ordering.
function libraryAllUrl(server, sectionId, opts) {
  opts = opts || {}
  var params = []
  if (opts.sort) params.push("sort=" + opts.sort)
  if (opts.start !== undefined) params.push("X-Plex-Container-Start=" + opts.start)
  if (opts.size !== undefined) params.push("X-Plex-Container-Size=" + opts.size)
  var url = server + "/library/sections/" + encodeURIComponent(String(sectionId)) + "/all"
  return params.length ? url + "?" + params.join("&") : url
}

function metadataUrl(server, ratingKey) {
  return server + "/library/metadata/" + encodeURIComponent(String(ratingKey))
}

function childrenUrl(server, ratingKey) {
  return server + "/library/metadata/" + encodeURIComponent(String(ratingKey)) + "/children"
}

// /search vs /hubs/search — probed both live with the same query.
// /search returns a single flat MediaContainer.Metadata array, already
// typed per item (movie/show/episode/album/...), pre-ranked by the server.
// /hubs/search instead buckets results into per-type Hub entries (Movies,
// Episodes, Tracks, Actors, Genres, ...), several of which (actor,
// director, genre, tag) carry no Metadata array at all — just tag stubs —
// so consuming it means special-casing hub types before you even get to
// an item shape. /search's flat, uniformly-typed array is simpler, so that is
// the one used here. Full comparison in docs/PLEX-API.md.
function searchUrl(server, query) {
  return server + "/search?query=" + encodeURIComponent(String(query || "").trim())
}

// path is server-relative (as Plex hands back in thumb/art/etc — e.g.
// "/library/metadata/3291/thumb/..."). The transcode endpoint resolves a
// relative url= against its own host, so there is no need to prefix it with
// server — doing so would only double-encode a host QML's Image never needs.
// Token-in-query is the one exception to the headers-only rule: QML Image
// cannot send headers.
function imageUrl(server, token, path, w, h) {
  if (!path) return ""
  var enc = encodeURIComponent(path)
  return server + "/photo/:/transcode?width=" + w + "&height=" + h +
    "&minSize=1&upscale=1&url=" + enc + "&X-Plex-Token=" + token
}

// ---- shared formatting helpers ----

// ms -> "1h 52m" / "52m" / "2h" (whole hours drop the "0m"). Distinct from
// Model.js's fmtDuration, which formats SECONDS as h:mm:ss for the seek bar
// readout — a different consumer.
function durationText(ms) {
  var totalMin = Math.max(0, Math.round((Number(ms) || 0) / 60000))
  var h = Math.floor(totalMin / 60)
  var m = totalMin % 60
  if (h <= 0) return m + "m"
  return m === 0 ? h + "h" : h + "h " + m + "m"
}

// viewOffset/duration clamped 0..1; either field missing or a zero/negative
// duration (seen on some show/season stubs that have no Media) is "0",
// never NaN or Infinity.
function progressFor(m) {
  var vo = Number(m && m.viewOffset)
  var dur = Number(m && m.duration)
  if (!vo || !dur || dur <= 0) return 0
  return Math.max(0, Math.min(1, vo / dur))
}

// bool for movie/episode (viewCount is often absent entirely rather than 0);
// leafCount-viewedLeafCount count for show/season.
function unwatchedFor(m) {
  if (m.type === "show" || m.type === "season") {
    var leaf = Number(m.leafCount) || 0
    var viewed = Number(m.viewedLeafCount) || 0
    return Math.max(0, leaf - viewed)
  }
  return !(Number(m.viewCount) > 0)
}

// Row/card text is deliberately split by browse context (DESIGN.md:
// posters for movie/show/season libraries and shelves, rows for episodes/
// search/Continue Watching): `sub` carries the context a row needs (which
// show, which year), `caption` carries the descriptor a poster's second
// line wants (rating, episode count). Both are always populated so either
// component reads sensibly regardless of which one a given page uses.
function subFor(m) {
  if (m.type === "episode") return cap(m.grandparentTitle, MAX_FIELD)
  if (m.type === "season") return cap(m.parentTitle, MAX_FIELD)
  return cap(m.year, MAX_FIELD)
}

function captionFor(m) {
  if (m.type === "episode") return "S" + ((m.parentIndex === undefined || m.parentIndex === null ? "?" : m.parentIndex)) + "E" + ((m.index === undefined || m.index === null ? "?" : m.index))
  if (m.type === "season") return (Number(m.leafCount) || 0) + " episodes"
  return cap(m.contentRating, MAX_FIELD)
}

// Image path choice: episodes only ever have a landscape (16:9) thumb, so
// thumbPath is naturally correct there. Movies/shows/seasons have a 2:3 poster
// thumb; their wide backdrop lives in `art` (episodes fall back to
// grandparentArt via `art`, which Plex resolves itself). Callers building a
// Continue Watching row pick thumbPath (episodes) or artPath (movies)
// themselves — that per-context choice is MediaRow's job, not this file's.
function thumbPathFor(m) {
  return cap(m.thumb, 512)
}

function artPathFor(m) {
  return cap(m.art || m.grandparentArt, 512)
}

// The one item shape every mapper below builds towards.
function itemFromMetadata(m) {
  return {
    ratingKey: keyOf(m.ratingKey),
    title: cap(m.title, MAX_FIELD),
    sub: subFor(m),
    caption: captionFor(m),
    thumbPath: thumbPathFor(m),
    artPath: artPathFor(m),
    type: cap(m.type, 32),
    progress: progressFor(m),
    durationText: durationText(m.duration),
    year: cap(m.year, 8),
    unwatched: unwatchedFor(m)
  }
}

// Shared walk: collect a MediaContainer's Metadata array (bounded, type-
// filtered) into item shapes. Every list endpoint (onDeck, recentlyAdded,
// library/all, search, children) returns this same flat shape — there is no
// SearchResults-nesting to handle here, unlike Model.js's mapItems.
function mapMetadataList(json) {
  var mc = json && json.MediaContainer
  var meta = (mc && mc.Metadata) || []
  var out = []
  for (var i = 0; i < meta.length && out.length < MAX_ITEMS; i++) {
    var m = meta[i]
    if (!m || !ITEM_TYPES[m.type]) continue
    out.push(itemFromMetadata(m))
  }
  return out
}

function mapItems(json) {
  return mapMetadataList(json)
}

function mapSearch(json) {
  return mapMetadataList(json)
}

function mapChildren(json) {
  return mapMetadataList(json)
}

// Video libraries only: a server also carries "artist" sections (Music,
// Audiobooks) that must never surface here.
function mapSections(json) {
  var mc = json && json.MediaContainer
  var dirs = (mc && mc.Directory) || []
  var out = []
  for (var i = 0; i < dirs.length; i++) {
    var d = dirs[i]
    if (d.type !== "movie" && d.type !== "show") continue
    out.push({ id: cap(d.key, MAX_KEY), title: cap(d.title, MAX_FIELD), type: d.type })
  }
  return out
}

// ---- audio / subtitle streams ----
//
// Plex hangs the per-file stream list off Media[].Part[].Stream[], with
// `streamType` as the discriminator. The panel needs it to offer a track
// picker: lots of this library is dubbed, so "which audio" is a real
// question, and subtitles are only reachable by id.
var STREAM_VIDEO = 1
var STREAM_AUDIO = 2
var STREAM_SUBTITLE = 3

// A row has to name itself even when Plex gives it nothing to be named by.
// extendedDisplayTitle is the one a PICKER wants: it is the only field that
// separates two dubs of the same language ("Nuovo doppiaggio (Italiano AC3
// 5.1)" vs "Doppiaggio Storico (Italiano AC3 Stereo)") or two fansubs of the
// same one ("English [Netflix] (ASS)"). Take it verbatim — its composition
// rule is not a template you can rebuild from the other fields; it reorders
// itself depending on whether a custom `title` exists, whether the stream is
// `forced`, and whether `language` matches Plex's canonical name for it.
// displayTitle is the short fallback, and a stream with neither gets language
// and codec assembled by hand rather than rendering as a blank row.
function streamLabel(s) {
  var ext = cap(s.extendedDisplayTitle, MAX_FIELD)
  if (ext !== "") return ext
  var disp = cap(s.displayTitle, MAX_FIELD)
  if (disp !== "") return disp
  var parts = []
  var lang = cap(s.language || s.languageTag || s.languageCode, MAX_FIELD)
  if (lang !== "") parts.push(lang)
  var codec = cap(s.codec, 32)
  if (codec !== "") parts.push(codec.toUpperCase())
  return parts.length ? parts.join(" · ") : "Track"
}

// `selected`, `default` and `forced` are OMITTED ENTIRELY when false — never
// serialized as `false`. Verified live across ~15 items and 60+ streams,
// including a 20-subtitle episode where 19 of them simply had no `selected`
// key. So the test is `=== true`, and every read has to be
// undefined-safe rather than assuming the field exists.
function streamFlag(v) {
  return v === true || v === 1 || v === "1"
}

// Qt's FFmpeg backend only ever reads a subtitle rect's TEXT payload
// (AVSubtitleRect.text / .ass); the bitmap payload (.pict) is never touched.
// So image-based subtitles cannot render in the internal player at all — and
// this matters here rather than being a footnote: the probed library is full
// of them (Akira ships PGS, PGS, VOBSUB and exactly one SRT). A picker that
// offered all four identically would silently do nothing three times out of
// four, so image subs are flagged and routed through the server instead.
var IMAGE_SUB_CODECS = {
  pgs: true, hdmv_pgs_subtitle: true,
  vobsub: true, dvd_subtitle: true, dvdsub: true,
  dvb_subtitle: true, dvbsub: true, xsub: true
}

function isImageSubCodec(codec) {
  return IMAGE_SUB_CODECS[String(codec || "").toLowerCase()] === true
}

// `ordinal` is the one field the players need and the one Plex does not send:
// the stream's position among the EMBEDDED streams of its own type. Plex's own
// `index` is no substitute — it counts across ALL types in container order
// (one video, four audio and four subtitle streams index as 0, 1-4, 5-8), whereas
// QtMultimedia's audioTracks[] index and mpv's 1-based aid/sid both count
// within one type. A sidecar file is in no container at all, so it gets
// ordinal -1: it exists only as a server-side selection.
function mapStream(s, ordinal, isSubtitle) {
  return {
    id: cap(s.id, MAX_KEY),
    index: s.index === undefined || s.index === null ? -1 : (Number(s.index) | 0),
    ordinal: ordinal,
    label: streamLabel(s),
    language: cap(s.language || s.languageTag || s.languageCode, MAX_FIELD),
    codec: cap(s.codec, 32),
    channels: Number(s.channels) || 0,
    selected: streamFlag(s.selected),
    forced: streamFlag(s.forced),
    isDefault: streamFlag(s["default"]),
    // No stream carrying a `key` was found anywhere on the live server, so
    // this branch is defensive rather than verified — see docs/PLEX-API.md.
    external: String(s.key || "") !== "",
    image: isSubtitle === true && isImageSubCodec(s.codec)
  }
}

// Returns { partId, video[], audio[], subtitle[] } for the FIRST part of the
// first Media. Multi-part items (a film split across two files) would want a
// part picker of their own; `allParts=1` on the selection PUT at least keeps
// the halves in step. Tolerant by construction:
// a show or season carries no Media at all and must come back as empty lists
// rather than throwing.
function mapStreams(json) {
  var mc = json && json.MediaContainer
  var m = mc && mc.Metadata && mc.Metadata[0]
  var media = m && m.Media && m.Media[0]
  var part = media && media.Part && media.Part[0]
  var streams = (part && part.Stream) || []
  var out = {
    partId: part ? cap(part.id, MAX_KEY) : "",
    video: [],
    audio: [],
    subtitle: []
  }
  // Counted per type, and only for muxed streams, because that is what the
  // ordinal means.
  var embedded = { 1: 0, 2: 0, 3: 0 }
  for (var i = 0; i < streams.length && i < MAX_ITEMS; i++) {
    var s = streams[i]
    if (!s) continue
    var t = Number(s.streamType)
    var bucket = t === STREAM_AUDIO ? out.audio
      : (t === STREAM_SUBTITLE ? out.subtitle
        : (t === STREAM_VIDEO ? out.video : null))
    if (!bucket) continue
    var sidecar = String(s.key || "") !== ""
    bucket.push(mapStream(s, sidecar ? -1 : embedded[t]++, t === STREAM_SUBTITLE))
  }
  return out
}

// The id Plex currently has selected, or "" for none. Subtitles legitimately
// have none selected; audio in practice always has one, but a file Plex has
// not analyzed can come back with no flag at all, so both callers have to
// cope with "".
function selectedStreamId(list) {
  var streams = list || []
  for (var i = 0; i < streams.length; i++) if (streams[i] && streams[i].selected) return streams[i].id
  return ""
}

// PUT this before a transcode starts and the transcode inherits the choice.
// `allParts=1` applies it to every part of a multi-part item. Sending "0" for
// subtitleStreamID is Plex's "no subtitles".
function partSelectionUrl(server, partId, audioStreamId, subtitleStreamId) {
  var params = []
  if (audioStreamId !== undefined && audioStreamId !== null && String(audioStreamId) !== "")
    params.push("audioStreamID=" + encodeURIComponent(String(audioStreamId)))
  if (subtitleStreamId !== undefined && subtitleStreamId !== null && String(subtitleStreamId) !== "")
    params.push("subtitleStreamID=" + encodeURIComponent(String(subtitleStreamId)))
  params.push("allParts=1")
  return server + "/library/parts/" + encodeURIComponent(String(partId)) + "?" + params.join("&")
}

// Detail page: base item shape plus the extras a hero/season list needs.
// rating: movies carry a top-level critic `rating`; shows never do (only
// `audienceRating` + a `Rating[]` array) — fall back so the hero always has a
// number to show. Genre is entirely absent on episode metadata, so genres is
// always an array, never undefined.
function mapDetail(json) {
  var mc = json && json.MediaContainer
  var m = mc && mc.Metadata && mc.Metadata[0]
  if (!m) return null
  var genres = []
  var Genre = m.Genre || []
  for (var i = 0; i < Genre.length; i++) if (Genre[i] && Genre[i].tag) genres.push(cap(Genre[i].tag, MAX_FIELD))
  var media = null
  if (m.Media && m.Media[0]) {
    var md = m.Media[0]
    media = {
      videoResolution: cap(md.videoResolution, 16),
      container: cap(md.container, 16),
      videoCodec: cap(md.videoCodec, 16),
      audioCodec: cap(md.audioCodec, 16),
      width: Number(md.width) || 0,
      height: Number(md.height) || 0,
      bitrate: Number(md.bitrate) || 0
    }
  }
  var item = itemFromMetadata(m)
  item.summary = cap(m.summary, 4096)
  item.rating = m.rating !== undefined ? Number(m.rating) : (m.audienceRating !== undefined ? Number(m.audienceRating) : null)
  item.contentRating = cap(m.contentRating, 32)
  item.genres = genres
  item.media = media
  item.tagline = cap(m.tagline, MAX_FIELD)
  item.studio = cap(m.studio, MAX_FIELD)
  item.directors = tagList(m.Director, 4)
  item.writers = tagList(m.Writer, 4)
  item.ratings = ratingsFor(m)
  // The hero's Video/Audio lines use Plex's SHORT displayTitle ("4K DoVi/HDR10
  // (HEVC Main 10)"), not the picker's extendedDisplayTitle, which drags in
  // whatever release-group name the file's track title carries.
  item.videoText = ""
  item.audioText = ""
  item.subtitleCount = 0
  var part = m.Media && m.Media[0] && m.Media[0].Part && m.Media[0].Part[0]
  var raw = (part && part.Stream) || []
  var firstAudio = ""
  for (var k = 0; k < raw.length && k < MAX_ITEMS; k++) {
    var st = raw[k]
    if (!st) continue
    var t = Number(st.streamType)
    var label = cap(st.displayTitle || st.extendedDisplayTitle, MAX_FIELD)
    if (t === STREAM_VIDEO && item.videoText === "") item.videoText = label
    else if (t === STREAM_AUDIO) {
      if (firstAudio === "") firstAudio = label
      if (streamFlag(st.selected) && item.audioText === "") item.audioText = label
    } else if (t === STREAM_SUBTITLE) item.subtitleCount++
  }
  if (item.audioText === "") item.audioText = firstAudio
  item.cast = castFor(m.Role)
  item.extras = extrasFor(m.Extras)
  return item
}

// ---- detail-page extras (movie page, the stock-Plex layout) ----
// Cast, ratings and extras come back in the metadata request itself (see
// detailUrl). Related does NOT ride along: includeRelated made that request
// take ~1.5 s instead of ~30 ms (measured 2026-10-23), and the whole page
// waited on it. relatedUrl fetches the same hubs separately, after the page
// has drawn.

function detailUrl(server, ratingKey) {
  return metadataUrl(server, ratingKey) + "?includeOnDeck=1&includeExtras=1"
}

function relatedUrl(server, ratingKey) {
  return server + "/hubs/metadata/" + encodeURIComponent(String(ratingKey)) + "/related"
}

// /hubs/metadata/{key}/related hands back { MediaContainer: { Hub: [...] } },
// the same Hub list includeRelated nests under Metadata[0].Related.
function mapRelated(json) {
  return relatedFor(json && json.MediaContainer)
}

function tagList(tags, limit) {
  var out = []
  var list = tags || []
  for (var i = 0; i < list.length && out.length < limit; i++)
    if (list[i] && list[i].tag) out.push(cap(list[i].tag, MAX_FIELD))
  return out
}

// Plex's Rating[] names its source only through an image URI:
// imdb://image.rating, rottentomatoes://image.rating.ripe (critic; "rotten"
// when bad), rottentomatoes://image.rating.upright (audience; "spilled" when
// bad), themoviedb://image.rating. Values are 0-10; RT and TMDB are shown as
// the percentages their own sites use.
function ratingsFor(m) {
  var out = []
  var list = m.Rating || []
  for (var i = 0; i < list.length && out.length < 6; i++) {
    var r = list[i]
    if (!r || r.value === undefined || r.value === null) continue
    var img = String(r.image || "")
    var v = Number(r.value)
    if (!isFinite(v)) continue
    var pct = Math.round(v * 10) + "%"
    if (img.indexOf("imdb://") === 0) out.push("IMDb " + v.toFixed(1))
    else if (img.indexOf("rottentomatoes://") === 0)
      out.push((r.type === "critic" ? "Critics " : "Audience ") + pct)
    else if (img.indexOf("themoviedb://") === 0) out.push("TMDB " + pct)
  }
  return out
}

// Role thumbs are absolute https URLs on metadata-static.plex.tv; the photo
// transcoder fetches those itself, so they go through imageUrl like any
// library path.
function castFor(roles) {
  var out = []
  var list = roles || []
  for (var i = 0; i < list.length && out.length < 30; i++) {
    var r = list[i]
    if (!r || !r.tag) continue
    out.push({ name: cap(r.tag, MAX_FIELD), role: cap(r.role, MAX_FIELD), photoPath: cap(r.thumb, 512) })
  }
  return out
}

var EXTRA_KINDS = {
  trailer: "Trailer", scene: "Scene", behindTheScenes: "Behind the Scenes",
  interview: "Interview", deletedScene: "Deleted Scene", featurette: "Featurette",
  short: "Short", clip: "Clip"
}

// Extras are `clip` metadata with their own ratingKey and a playable part, so
// playItem() handles them unchanged.
function extrasFor(extras) {
  var out = []
  var list = (extras && extras.Metadata) || []
  for (var i = 0; i < list.length && out.length < 30; i++) {
    var x = list[i]
    if (!x || !x.ratingKey) continue
    out.push({
      ratingKey: keyOf(x.ratingKey),
      title: cap(x.title, MAX_FIELD),
      kind: EXTRA_KINDS[String(x.subtype || "")] || "Extra",
      thumbPath: cap(x.thumb, 512),
      durationText: x.duration ? durationText(x.duration) : ""
    })
  }
  return out
}

// Related arrives as hubs (movie.similar is the "Related Movies" row); take
// the first one that has items, filtered like every other list.
function relatedFor(related) {
  var hubs = (related && related.Hub) || []
  for (var h = 0; h < hubs.length; h++) {
    var items = mapMetadataList({ MediaContainer: hubs[h] })
    // Stock Plex captions these with the year, not the content rating.
    for (var i = 0; i < items.length; i++) items[i].caption = items[i].year
    if (items.length > 0) return items.slice(0, 30)
  }
  return []
}

// One card per entry of recentlyAddedHubUrl, shaped like stock Plex's row:
// always the SHOW's poster and name on top, then what is new underneath.
//   show    -> "19 seasons"
//   season  -> "Season 3"
//   episode -> episode title, then "S5 · E6"
// `badge` is the unwatched count Plex paints on a show/season poster's corner.
// `target*` is where activating the card goes: a season opens that season, an
// episode opens its show (an episode has no detail page of its own here).
function mapRecentShows(json) {
  var mc = json && json.MediaContainer
  var meta = (mc && mc.Metadata) || []
  var out = []
  for (var i = 0; i < meta.length && out.length < MAX_ITEMS; i++) {
    var m = meta[i]
    if (!m || !ITEM_TYPES[m.type] || m.type === "movie") continue
    var item = itemFromMetadata(m)
    var leaf = Number(m.leafCount) || 0
    var unwatched = Math.max(0, leaf - (Number(m.viewedLeafCount) || 0))
    if (m.type === "show") {
      var seasons = Number(m.childCount) || 0
      item.caption = seasons > 0 ? seasons + (seasons === 1 ? " season" : " seasons") : ""
      item.caption2 = ""
      item.badge = unwatched > 0 ? String(unwatched) : ""
      item.targetKey = item.ratingKey
      item.targetType = "show"
    } else if (m.type === "season") {
      item.title = cap(m.parentTitle, MAX_FIELD)
      item.thumbPath = cap(m.parentThumb || m.thumb, 512)
      item.caption = cap(m.title, MAX_FIELD)
      item.caption2 = ""
      item.badge = unwatched > 0 ? String(unwatched) : ""
      item.targetKey = item.ratingKey
      item.targetType = "season"
    } else {
      item.title = cap(m.grandparentTitle, MAX_FIELD)
      item.thumbPath = cap(m.grandparentThumb || m.parentThumb || m.thumb, 512)
      item.caption = cap(m.title, MAX_FIELD)
      item.caption2 = "S" + (m.parentIndex === undefined || m.parentIndex === null ? "?" : m.parentIndex) +
        " · E" + (m.index === undefined || m.index === null ? "?" : m.index)
      item.badge = ""
      item.targetKey = keyOf(m.grandparentRatingKey) || item.ratingKey
      item.targetType = m.grandparentRatingKey ? "show" : "episode"
    }
    out.push(item)
  }
  return out
}
