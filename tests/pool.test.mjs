// Pool.js unit tests: the request pool's queue and slot bookkeeping, loaded the
// same way Model.js is (plain script, fresh vm context). The Processes
// themselves are faked: `launch` records what would have run, and the tests
// play the stream / exit / start-failure events back in whatever order the
// scenario needs.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Pool.js"), "utf8")

function loadPool() {
  const ctx = vm.createContext({})
  vm.runInContext(
    source +
      "\nthis.P = { createPool, enqueue, dropQueued, pump, streamFinished, exited," +
      " startFailed, deliver, busyCount }",
    ctx
  )
  return ctx.P
}

const P = loadPool()

// A tiny stand-in for PlexPanel's wiring: every settle delivers, then pumps.
function harness(slots = 4, isStale = null) {
  const pool = P.createPool(slots)
  const launched = [] // [slotIndex, path] in launch order
  const pump = () => P.pump(pool, isStale, (i, job) => launched.push([i, job.path]))
  const done = (d) => { const err = P.deliver(d); pump(); return err }
  return {
    pool, launched, pump,
    request(path, cb, extra = {}) { P.enqueue(pool, { path, cb, raw: false, page: "", tag: "", ...extra }); pump() },
    stream(i, text) { return done(P.streamFinished(pool, i, text)) },
    exit(i) { return done(P.exited(pool, i)) },
    failStart(i) { return done(P.startFailed(pool, i)) },
  }
}

test("six jobs over four slots run FIFO, and the overflow waits for a free slot", () => {
  const h = harness(4)
  for (let n = 0; n < 6; n++) h.request("/j" + n, () => {})
  assert.deepEqual(h.launched.map(l => l[1]), ["/j0", "/j1", "/j2", "/j3"])
  assert.equal(h.pool.queue.length, 2)
  h.stream(2, "{}")
  assert.equal(h.launched.length, 4, "a stream end alone must not free the slot")
  h.exit(2)
  assert.deepEqual(h.launched[4], [2, "/j4"], "freed slot takes the oldest queued job")
  h.exit(0); h.stream(0, "{}")
  assert.deepEqual(h.launched[5], [0, "/j5"])
  assert.equal(h.pool.queue.length, 0)
})

test("stream-then-exit and exit-then-stream both settle exactly once", () => {
  for (const order of [["stream", "exit"], ["exit", "stream"]]) {
    const h = harness(1)
    const got = []
    h.request("/a", (doc) => got.push(doc))
    h.request("/b", () => {})
    for (const step of order) {
      assert.equal(got.length, 0, `${order} must wait for both halves`)
      if (step === "stream") h.stream(0, '{"ok":1}')
      else h.exit(0)
    }
    // JSON.parse ran inside the vm realm, so compare by value, not prototype.
    assert.equal(JSON.stringify(got), '[{"ok":1}]', `${order}`)
    assert.deepEqual(h.launched.map(l => l[1]), ["/a", "/b"], `${order} pumps the next job`)
    // A late duplicate event for the old job must not settle the new one.
    assert.equal(P.busyCount(h.pool), 1)
  }
})

test("a throwing callback still frees its slot and the queue keeps moving", () => {
  const h = harness(1)
  const after = []
  h.request("/dead-page", () => { throw new TypeError("page is null") })
  h.request("/next", (doc) => after.push(doc))
  h.stream(0, "{}")
  const err = h.exit(0)
  assert.ok(err instanceof Error || (err && err.name === "TypeError"), "error is handed back for logging")
  assert.deepEqual(h.launched.map(l => l[1]), ["/dead-page", "/next"])
  h.stream(0, "[1]"); h.exit(0)
  assert.equal(after.length, 1)
  assert.equal(P.busyCount(h.pool), 0)
})

test("a process that never started settles as a failed request: cb(null)", () => {
  const h = harness(1)
  const got = []
  h.request("/x", (doc) => got.push(doc))
  h.request("/y", (doc) => got.push(doc))
  h.failStart(0)
  assert.deepEqual(got, [null])
  assert.deepEqual(h.launched.map(l => l[1]), ["/x", "/y"], "the slot is reusable after a start failure")
  // A raw job gets the empty string rather than null.
  const r = harness(1)
  const raw = []
  r.request("/raw", (t) => raw.push(t), { raw: true })
  r.failStart(0)
  assert.deepEqual(raw, [""])
})

test("HTTP failures (empty body under --fail) and bad JSON give cb(null)", () => {
  const h = harness(2)
  const got = []
  h.request("/a", (d) => got.push(d))
  h.request("/b", (d) => got.push(d))
  h.stream(0, ""); h.exit(0)
  h.stream(1, "<html>"); h.exit(1)
  assert.deepEqual(got, [null, null])
})

test("queued jobs for a page that is no longer on screen are dropped, untagged ones never", () => {
  let current = "home"
  const h = harness(1, (job) => job.page !== "" && job.page !== current)
  const ran = []
  h.request("/busy", () => ran.push("busy"))
  h.request("/home-shelf", () => ran.push("home-shelf"), { page: "home" })
  h.request("/sidebar", () => ran.push("sidebar"))
  h.request("/detail", () => ran.push("detail"), { page: "detail" })
  current = "detail"
  h.stream(0, "{}"); h.exit(0)
  assert.deepEqual(h.launched.map(l => l[1]), ["/busy", "/sidebar"], "home's job skipped, untagged kept")
  h.stream(0, "{}"); h.exit(0)
  assert.deepEqual(h.launched.map(l => l[1]), ["/busy", "/sidebar", "/detail"])
  h.stream(0, "{}"); h.exit(0)
  assert.deepEqual(ran, ["busy", "sidebar", "detail"])
})

test("dropQueued removes only queued jobs with the tag", () => {
  const h = harness(1)
  h.request("/inflight", () => {}, { tag: "t" })
  h.request("/q1", () => {}, { tag: "t" })
  h.request("/q2", () => {}, { tag: "other" })
  assert.equal(P.dropQueued(h.pool, (j) => j.tag === "t"), 1)
  assert.deepEqual([...h.pool.queue].map(j => j.path), ["/q2"])
  assert.equal(P.busyCount(h.pool), 1, "in-flight job is left to finish")
})
