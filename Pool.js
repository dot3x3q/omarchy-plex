// The request pool's bookkeeping: a FIFO queue feeding a fixed number of
// process slots. Plain script, no module syntax — the same file loads as a QML
// JavaScript resource for the panel and runs under node:vm for unit tests
// (tests/pool.test.mjs), exactly like Model.js and Api.js.
//
// Nothing in here touches a Process. PlexPanel.qml owns the four curl
// Processes and reports their events in (streamFinished / exited /
// startFailed); this file decides when a slot is free, which job runs next and
// what the callback is handed. That split exists so the parts that wedged the
// queue in the past — a callback that threw, a slot freed one event too
// early, a process that never started — can be exercised without a shell.

function createPool(slotCount) {
  var slots = []
  for (var i = 0; i < slotCount; i++) slots.push(freshSlot())
  return { queue: [], slots: slots }
}

function freshSlot() {
  return { busy: false, streamDone: false, exitDone: false, body: "", job: null }
}

// job: { path, cb, tag, raw }. `tag` is opaque here; the caller's isStale
// predicate gives it meaning. `raw` hands the callback the body string instead
// of the parsed JSON.
function enqueue(pool, job) {
  pool.queue.push(job)
}

// Forget every QUEUED job the predicate matches. In-flight jobs are left to
// finish: their process is already running, and killing curl mid-response buys
// nothing but a log line.
function dropQueued(pool, match) {
  var kept = []
  var dropped = 0
  for (var i = 0; i < pool.queue.length; i++) {
    if (match(pool.queue[i])) dropped++
    else kept.push(pool.queue[i])
  }
  pool.queue = kept
  return dropped
}

// Hand queued jobs to free slots, oldest first. A job the caller now
// considers stale (its page is gone) is discarded on the way out of the queue
// rather than run, so a page you left does not spend the slots the page you
// are looking at needs. Its callback is not called: whoever asked no longer
// exists to be told.
function pump(pool, isStale, launch) {
  for (var i = 0; i < pool.slots.length; i++) {
    var slot = pool.slots[i]
    if (slot.busy) continue
    var job = null
    while (pool.queue.length > 0) {
      var next = pool.queue.shift()
      if (isStale && isStale(next)) continue
      job = next
      break
    }
    if (job === null) return
    slot.busy = true
    slot.streamDone = false
    slot.exitDone = false
    slot.body = ""
    slot.job = job
    launch(i, job)
  }
}

// The three events a slot's process can report. Each returns either null (the
// slot is still waiting on the other half) or the finished { job, body }, by
// which point the slot is already free for the next pump.
//
// A slot settles only once BOTH its stdout stream has ended and the process
// has exited. Quickshell emits the stream end first, from inside its own
// finish handler and before `exited`; freeing the slot on the stream alone
// would launch the next job into it, and the old process's `exited`, arriving
// a moment later, would then be counted against the new job.
function streamFinished(pool, index, text) {
  var slot = pool.slots[index]
  if (!slot || !slot.busy) return null
  slot.body = String(text === undefined || text === null ? "" : text)
  slot.streamDone = true
  return settle(pool, index)
}

function exited(pool, index) {
  var slot = pool.slots[index]
  if (!slot || !slot.busy) return null
  slot.exitDone = true
  return settle(pool, index)
}

// A process that never started (curl missing, fork failure) emits neither a
// stream end nor an exit — Quickshell only drops `running` back to false. Left
// alone that slot stays busy for the life of the shell, and four of them wedge
// every page. Treat it as an empty response, which callers already read as
// "request failed".
function startFailed(pool, index) {
  var slot = pool.slots[index]
  if (!slot || !slot.busy) return null
  slot.body = ""
  slot.streamDone = true
  slot.exitDone = true
  return settle(pool, index)
}

function settle(pool, index) {
  var slot = pool.slots[index]
  if (!slot.streamDone || !slot.exitDone) return null
  var done = { job: slot.job, body: slot.body }
  pool.slots[index] = freshSlot()
  return done
}

// Run the job's callback. --fail leaves stdout empty on any HTTP error, so a
// parse failure and a transport failure land in the same place: cb(null) (or
// cb("") for a raw job). A callback that throws — typically one whose page has
// been destroyed, so its ids resolve to null — must not take the pump down
// with it; the error is returned for the caller to log instead.
function deliver(done) {
  if (!done || !done.job || typeof done.job.cb !== "function") return null
  var payload
  if (done.job.raw === true) {
    payload = String(done.body || "")
  } else {
    try { payload = JSON.parse(String(done.body || "")) } catch (e) { payload = null }
  }
  try {
    done.job.cb(payload)
  } catch (e2) {
    return e2
  }
  return null
}

function busyCount(pool) {
  var n = 0
  for (var i = 0; i < pool.slots.length; i++) if (pool.slots[i].busy) n++
  return n
}
