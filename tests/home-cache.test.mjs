// HomeCache.js unit tests, loaded the same way Pool.js is (plain script, fresh
// vm context).

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../HomeCache.js", import.meta.url), "utf8")
const ctx = vm.createContext({})
vm.runInContext(source, ctx)
const H = ctx
// vm objects carry another realm's prototypes; compare as plain JSON.
const plain = (v) => JSON.parse(JSON.stringify(v))

const S = "http://plex:32400"
const movie = { ratingKey: "1", title: "Heat", type: "movie", thumbPath: "/library/metadata/1/thumb/9", year: 1995, watched: false }
const shelves = [{ id: "1", title: "Movies", type: "movie" }, { id: "2", title: "TV Shows", type: "show" }]

test("round-trips through serialize/parse for the same server", () => {
  let c = H.withShelfList(null, S, shelves)
  c = H.withOnDeck(c, S, [movie])
  c = H.withShelf(c, S, "1", [movie])
  const back = H.parse(H.serialize(c), S)
  assert.deepEqual(plain(H.onDeckItems(back, S)), [movie])
  assert.deepEqual(plain(H.shelfItems(back, S, "1")), [movie])
  assert.equal(H.shelfItems(back, S, "2"), null, "never-fetched shelf is a miss, not empty")
  assert.deepEqual(plain(back.shelfList), shelves)
})

test("another server's cache is ignored and replaced", () => {
  const c = H.withShelf(null, S, "1", [movie])
  assert.equal(H.parse(H.serialize(c), "http://other:32400"), null)
  assert.equal(H.shelfItems(c, "http://other:32400", "1"), null)
  const d = H.withOnDeck(c, "http://other:32400", [])
  assert.equal(d.server, "http://other:32400")
  assert.equal(H.shelfItems(d, "http://other:32400", "1"), null)
})

test("updates are copy-on-write", () => {
  const a = H.withShelf(null, S, "1", [movie])
  const b = H.withShelf(a, S, "2", [])
  assert.notEqual(a, b)
  assert.equal(H.shelfItems(a, S, "2"), null)
})

test("dropping a library drops its row", () => {
  let c = H.withShelfList(null, S, shelves)
  c = H.withShelf(c, S, "2", [movie])
  c = H.withShelfList(c, S, [shelves[0]])
  assert.equal(H.shelfItems(c, S, "2"), null)
})

test("parse rejects junk, wrong version and oversize input", () => {
  assert.equal(H.parse("", S), null)
  assert.equal(H.parse("{nope", S), null)
  assert.equal(H.parse(JSON.stringify({ v: 99, server: S }), S), null)
  assert.equal(H.parse("x".repeat(H.MAX_BYTES + 1), S), null)
})

test("parse keeps only flat primitive fields and bounded lists", () => {
  const evil = { ...movie, nested: { a: 1 }, fn: [1, 2], nan: NaN }
  const many = Array.from({ length: 500 }, (_, i) => ({ ratingKey: String(i) }))
  const text = JSON.stringify({ v: 1, server: S, onDeck: [evil, "str", null],
    shelfList: [...shelves, { id: "3", title: "Music", type: "artist" }], shelves: { "1": many, "3": [movie] } })
  const c = H.parse(text, S)
  assert.deepEqual(plain(c.onDeck), [{ ...movie, nan: undefined }].map(plain))
  assert.equal(c.shelves["1"].length, H.MAX_ITEMS)
  assert.equal(c.shelfList.length, 2, "non-video library refused")
  assert.equal(H.shelfItems(c, S, "3"), null)
})

test("serialize refuses a cache the bounded read could not take back", () => {
  const big = Array.from({ length: 64 }, (_, i) => ({ ratingKey: String(i), summary: "x".repeat(1024) }))
  let c = H.withShelfList(null, S, Array.from({ length: 8 }, (_, i) => ({ id: String(i), title: "L", type: "movie" })))
  for (let i = 0; i < 8; i++) c = H.withShelf(c, S, String(i), big)
  assert.equal(H.serialize(c), "")
})
