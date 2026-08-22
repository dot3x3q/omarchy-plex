// Plex Mini Model.js unit tests. Loads the QML-style script (plain function
// declarations, no module syntax) into a fresh vm context.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Model.js"), "utf8")

const ctx = vm.createContext({})
vm.runInNewContext(
  source +
    "\nthis.M = { validServer: validServer, validToken: validToken," +
    " mapItems: mapItems, fmtDuration: fmtDuration, parsePlaybackMetadata: parsePlaybackMetadata }",
  ctx
)
const M = ctx.M

test("validServer accepts http(s) origins with optional port", () => {
  assert.equal(M.validServer("http://192.168.10.249:32400"), true)
  assert.equal(M.validServer("https://plex.home.arpa"), true)
  assert.equal(M.validServer("https://plex.home.arpa:8443"), true) // port form is legal
})

test("validServer rejects paths and garbage", () => {
  assert.equal(M.validServer("http://host:32400/web"), false)
  assert.equal(M.validServer("ftp://host"), false)
  assert.equal(M.validServer("host"), false)
  assert.equal(M.validServer(""), false)
  assert.equal(M.validServer("http://host:32400?x=1"), false)
})

test("validToken enforces charset and length", () => {
  assert.equal(M.validToken("eiBEXAMPLExxxxxxxxxx"), true)
  assert.equal(M.validToken("short1"), false)
  assert.equal(M.validToken("has-dashes-123456"), false)
  assert.equal(M.validToken(""), false)
})

const onDeckContainer = {
  MediaContainer: {
    Metadata: [
      { ratingKey: "101", title: "Blade Runner", year: 1982 },
      { ratingKey: "202", title: "Shots", grandparentTitle: "The Bear", parentIndex: 1, index: 4 },
      { ratingKey: "303", title: "" }
    ]
  }
}

test("mapItems maps onDeck metadata to list-model shape", () => {
  const out = M.mapItems(onDeckContainer.MediaContainer, "onDeck")
  assert.equal(out.length, 3)
  assert.deepEqual([out[0].ratingKey, out[0].title], ["101", "Blade Runner"])
  // episodes render show + season/episode in the subtitle
  assert.equal(out[1].sub, "The Bear — S1E4")
  // movies fall back to year
  assert.equal(out[0].sub, "1982")
  // missing title never becomes the string "undefined"
  assert.equal(out[2].title, "")
})

test("mapItems flattens grouped search results without flatMap", () => {
  const searchContainer = {
    MediaContainer: {
      SearchResults: [
        { Metadata: [{ ratingKey: "1", title: "A", type: "movie" }] },
        { id: "no-metadata-here" },
        { Metadata: [{ ratingKey: "2", title: "B", type: "movie" }, { ratingKey: "3", title: "C", type: "movie" }] }
      ]
    }
  }
  const out = M.mapItems(searchContainer.MediaContainer, "search")
  assert.equal(out.map(i => i.ratingKey).join("|"), "1|2|3")
})

test("mapItems tolerates empty containers", () => {
  assert.equal(M.mapItems(null, "onDeck").length, 0)
  assert.equal(M.mapItems({ MediaContainer: {} }, "onDeck").length, 0)
})

test("fmtDuration renders hours only when present", () => {
  assert.equal(M.fmtDuration(0), "0:00")
  assert.equal(M.fmtDuration(59), "0:59")
  assert.equal(M.fmtDuration(61), "1:01")
  assert.equal(M.fmtDuration(27 * 60 + 12), "27:12")
  assert.equal(M.fmtDuration((2 * 3600) + (7 * 60) + 12), "2:07:12")
  assert.equal(M.fmtDuration(-5), "0:00")
})


test("mapItems caps item count and remote field lengths", () => {
  const mc = { Metadata: Array.from({ length: 400 }, (_, i) => ({ ratingKey: "k" + i, title: "T".repeat(500), type: "movie" })) }
  const out = M.mapItems(mc, "onDeck")
  assert.equal(out.length, 256)
  assert.equal(out[0].title.length, 256)
})

test("parsePlaybackMetadata extracts bounded part path and resume offset", () => {
  const doc = JSON.stringify({ MediaContainer: { Metadata: [{ viewOffset: 3706000, Media: [{ Part: [{ key: "/library/parts/1/file.mkv" }] }] }] } })
  const p = M.parsePlaybackMetadata(doc)
  assert.equal(p.partKey, "/library/parts/1/file.mkv")
  assert.equal(p.viewOffsetSec, 3706)
})

test("parsePlaybackMetadata rejects missing or foreign part paths", () => {
  assert.equal(M.parsePlaybackMetadata(JSON.stringify({ MediaContainer: { Metadata: [] } })), null)
  const foreign = JSON.stringify({ MediaContainer: { Metadata: [{ Media: [{ Part: [{ key: "https://evil.test/x" }] }] }] } })
  assert.equal(M.parsePlaybackMetadata(foreign), null)
})
