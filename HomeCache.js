// Home page cache: the last good Continue Watching list and each library's
// Recently Added row, so Home can draw at once and refresh behind itself.
// Plain script, no module syntax — loads as a QML JavaScript resource for the
// panel and under node:vm for tests/home-cache.test.mjs, like Pool.js.
//
// Why it exists: the TV row comes from /hubs/home/recentlyAdded, which Plex
// builds on every request (1.8–2.7 s measured on the owner's server, no
// warm-up), while the Movies row is a plain list at ~0.1 s. Nothing on our
// side makes the hub faster, so Home shows the last answer and swaps in the
// fresh one when it lands.
//
// What is stored is the MAPPED item (Api.mapItems / mapRecentShows output)
// with Plex's own relative thumbPath/artPath — never the resolved image URL,
// which carries the token. Pages resolve URLs at display time, as they do for
// fresh data. The cache is per server: switching servers ignores it.
//
// Shape: { v: 1, server, onDeck: [item] | null,
//          shelfList: [{ id, title, type }], shelves: { id: [item] } }

var CACHE_VERSION = 1
// The disk copy is read with one bounded dd; anything larger is not written.
var MAX_BYTES = 262144
var MAX_ITEMS = 64
var MAX_SHELVES = 32
var MAX_STRING = 1024

function empty(server) {
  return { v: CACHE_VERSION, server: String(server || ""), onDeck: null, shelfList: [], shelves: {} }
}

// The cache to build on for `server`: the current one when it matches,
// otherwise a fresh one (a server change drops everything).
function forServer(cache, server) {
  if (cache && cache.v === CACHE_VERSION && cache.server === String(server || "")) return cache
  return empty(server)
}

// Items are flat records of strings, numbers and booleans. Anything else is
// dropped rather than trusted — the disk copy is input like any other.
function cleanItem(it) {
  if (!it || typeof it !== "object" || Array.isArray(it)) return null
  var out = {}
  for (var k in it) {
    if (!Object.prototype.hasOwnProperty.call(it, k)) continue
    var v = it[k]
    if (typeof v === "string") out[k] = v.length > MAX_STRING ? v.slice(0, MAX_STRING) : v
    else if (typeof v === "number" && isFinite(v)) out[k] = v
    else if (typeof v === "boolean") out[k] = v
  }
  return out
}

function cleanItems(list) {
  if (!Array.isArray(list)) return null
  var out = []
  for (var i = 0; i < list.length && out.length < MAX_ITEMS; i++) {
    var it = cleanItem(list[i])
    if (it) out.push(it)
  }
  return out
}

function cleanShelfList(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length && out.length < MAX_SHELVES; i++) {
    var s = list[i]
    if (!s || typeof s.id !== "string" || s.id === "") continue
    if (s.type !== "movie" && s.type !== "show") continue
    out.push({ id: s.id, title: String(s.title || "").slice(0, MAX_STRING), type: s.type })
  }
  return out
}

// Copy-on-write updates: QML only notices a var property change on
// reassignment, so every update hands back a new object.
function withOnDeck(cache, server, items) {
  var c = forServer(cache, server)
  return { v: c.v, server: c.server, onDeck: cleanItems(items) || [], shelfList: c.shelfList, shelves: c.shelves }
}

function withShelfList(cache, server, list) {
  var c = forServer(cache, server)
  var shelfList = cleanShelfList(list)
  // Rows for libraries that are gone go with them.
  var shelves = {}
  for (var i = 0; i < shelfList.length; i++) {
    var id = shelfList[i].id
    if (Object.prototype.hasOwnProperty.call(c.shelves, id)) shelves[id] = c.shelves[id]
  }
  return { v: c.v, server: c.server, onDeck: c.onDeck, shelfList: shelfList, shelves: shelves }
}

function withShelf(cache, server, id, items) {
  var c = forServer(cache, server)
  var shelves = {}
  for (var k in c.shelves) if (Object.prototype.hasOwnProperty.call(c.shelves, k)) shelves[k] = c.shelves[k]
  shelves[String(id)] = cleanItems(items) || []
  return { v: c.v, server: c.server, onDeck: c.onDeck, shelfList: c.shelfList, shelves: shelves }
}

// Items for one shelf, or null when the cache has never seen it.
function shelfItems(cache, server, id) {
  if (!cache || cache.server !== String(server || "")) return null
  var key = String(id)
  return Object.prototype.hasOwnProperty.call(cache.shelves, key) ? cache.shelves[key] : null
}

function onDeckItems(cache, server) {
  if (!cache || cache.server !== String(server || "")) return null
  return cache.onDeck
}

// "" when the cache is too big for the bounded read to take back.
function serialize(cache) {
  if (!cache || !cache.server) return ""
  var s = JSON.stringify(cache)
  return s.length > MAX_BYTES ? "" : s
}

// Disk text → cache for `server`, or null when it is missing, oversize,
// malformed, another version, or another server's.
function parse(text, server) {
  var raw = String(text || "")
  if (raw === "" || raw.length > MAX_BYTES) return null
  var doc
  try { doc = JSON.parse(raw) } catch (e) { return null }
  if (!doc || typeof doc !== "object" || doc.v !== CACHE_VERSION) return null
  if (typeof doc.server !== "string" || doc.server === "" || doc.server !== String(server || "")) return null
  var c = empty(doc.server)
  c.onDeck = doc.onDeck === null || doc.onDeck === undefined ? null : cleanItems(doc.onDeck)
  c.shelfList = cleanShelfList(doc.shelfList)
  if (doc.shelves && typeof doc.shelves === "object") {
    for (var i = 0; i < c.shelfList.length; i++) {
      var id = c.shelfList[i].id
      if (!Object.prototype.hasOwnProperty.call(doc.shelves, id)) continue
      var items = cleanItems(doc.shelves[id])
      if (items) c.shelves[id] = items
    }
  }
  return c
}
