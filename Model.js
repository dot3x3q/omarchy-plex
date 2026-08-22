// Pure data logic for the Plex Mini panel: server/token validation, Plex
// API container mapping (Continue Watching and search results), and media
// time formatting. Plain script, no module syntax: the same file loads as
// a QML JavaScript resource for the panel and runs under node:vm for unit
// tests.

// A usable server is an http(s) origin with optional port. Anything else —
// a path, a bare hostname, a URL with a query already attached — would get
// the freshly entered token appended to every request.
function validServer(s) {
  return /^https?:\/\/[A-Za-z0-9.\-_]+(:\d+)?$/.test(String(s || ""))
}

// Plex tokens are opaque base64ish strings around 20 chars, letters/digits.
function validToken(t) {
  return /^[A-Za-z0-9]{10,}$/.test(String(t || ""))
}

var MAX_ITEMS = 256
var MAX_FIELD = 256
var MAX_KEY = 96

function cap(value, limit) {
  var s = String(value === undefined || value === null ? "" : value)
  return s.length > limit ? s.slice(0, limit) : s
}

// Map a /library/onDeck or /search MediaContainer into the list-model shape:
// [{ ratingKey, title, sub }]. Handles both response shapes (onDeck puts a
// flat Metadata array on the container; search nests arrays under
// SearchResults[].Metadata). Uses plain loops throughout — the QML JS
// engine (V4) has no Array.prototype.flatMap.
function mapItems(mc, op) {
  if (!mc) return []
  var meta = []
  if (op === "search" && mc.SearchResults) {
    for (var r = 0; r < mc.SearchResults.length && meta.length < MAX_ITEMS; r++) {
      var group = mc.SearchResults[r]
      if (!group || !group.Metadata) continue
      for (var k = 0; k < group.Metadata.length && meta.length < MAX_ITEMS; k++) meta.push(group.Metadata[k])
    }
  } else if (mc.Metadata) {
    for (var m2 = 0; m2 < mc.Metadata.length && meta.length < MAX_ITEMS; m2++) meta.push(mc.Metadata[m2])
  }
  var out = []
  for (var i = 0; i < meta.length; i++) {
    var m = meta[i]
    out.push({
      ratingKey: cap(m.ratingKey, MAX_KEY),
      title: cap(m.title, MAX_FIELD),
      sub: cap(m.grandparentTitle
        ? m.grandparentTitle + " — S" + (m.parentIndex || "?") + "E" + (m.index || "?")
        : (m.year || m.type || ""), MAX_FIELD)
    })
  }
  return out
}

// Seconds -> h:mm:ss or m:ss for the seek bar readout.
function fmtDuration(sec) {
  sec = Math.max(0, Math.floor(Number(sec) || 0))
  var h = Math.floor(sec / 3600)
  var m = Math.floor((sec % 3600) / 60)
  var s = sec % 60
  return h > 0 ? h + ":" + ("0" + m).slice(-2) + ":" + ("0" + s).slice(-2)
               : m + ":" + ("0" + s).slice(-2)
}

// Parse one /library/metadata response into the playback contract. Keeps
// remote strings bounded and requires an absolute Plex library part path.
function parsePlaybackMetadata(jsonText) {
  var doc = JSON.parse(jsonText)
  var md = doc && doc.MediaContainer && doc.MediaContainer.Metadata && doc.MediaContainer.Metadata[0]
  if (!md || !md.Media || !md.Media[0] || !md.Media[0].Part || !md.Media[0].Part[0]) return null
  var partKey = cap(md.Media[0].Part[0].key, 512)
  if (partKey.indexOf("/") !== 0) return null
  return {
    partKey: partKey,
    viewOffsetSec: Math.max(0, Math.round((Number(md.viewOffset) || 0) / 1000))
  }
}
