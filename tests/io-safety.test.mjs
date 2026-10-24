// Runtime receipts for the exact coreutils open flags used by PlexPanel.qml.
// These prove the single-open contract against regular, symlink, FIFO and
// oversized replacements rather than only asserting source text.

import { test } from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync, symlinkSync, rmSync } from "node:fs"
import { execFileSync, spawnSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"

function readBounded(dir, file, bytes) {
  const r = spawnSync("dd", [`if=${file}`, "iflag=nofollow,nonblock", `bs=${bytes + 1}`, "count=1", "status=none"], { cwd: dir })
  return r.stdout
}

function sandbox(fn) {
  const dir = mkdtempSync(join(tmpdir(), "omarchy-plex-io-"))
  try { fn(dir) } finally { rmSync(dir, { recursive: true, force: true }) }
}

test("regular config reads through the bounded descriptor", () => sandbox(dir => {
  writeFileSync(join(dir, "config.json"), '{"ok":1}')
  assert.equal(readBounded(dir, "config.json", 4096).toString(), '{"ok":1}')
}))

test("O_NOFOLLOW rejects a destination symlink", () => sandbox(dir => {
  symlinkSync("/etc/passwd", join(dir, "config.json"))
  assert.equal(readBounded(dir, "config.json", 4096).length, 0)
}))

test("O_NONBLOCK prevents a raced-in FIFO from hanging", () => sandbox(dir => {
  execFileSync("mkfifo", [join(dir, "config.json")])
  const started = Date.now()
  assert.equal(readBounded(dir, "config.json", 4096).length, 0)
  assert.ok(Date.now() - started < 1000)
}))

test("oversized input is capped one byte above the parser ceiling", () => sandbox(dir => {
  writeFileSync(join(dir, "config.json"), Buffer.alloc(5000, 65))
  assert.equal(readBounded(dir, "config.json", 4096).length, 4097)
}))

// ---- the panel's real scripts, run under sh in a sandboxed HOME ----
//
// Io.js is what PlexPanel.qml hands to `sh -c`, with paths and values as
// positional parameters. These run those exact strings against a throwaway
// directory tree, so a quoting slip shows up as a failed write or a followed
// symlink here rather than on 3x3q's real config.
import { readFileSync, mkdirSync, statSync, readdirSync, existsSync } from "node:fs"
import vm from "node:vm"

const ioSource = readFileSync(new URL("../Io.js", import.meta.url), "utf8")
const ioCtx = vm.createContext({})
vm.runInContext(ioSource, ioCtx)
const Io = ioCtx

function sh(script, args, opts = {}) {
  const r = spawnSync("sh", ["-c", script, "sh", ...args], {
    input: opts.input ?? "",
    cwd: opts.home ?? "/",
    env: { PATH: process.env.PATH, HOME: opts.home ?? "/nonexistent" },
  })
  return { code: r.status, out: r.stdout.toString(), err: r.stderr.toString() }
}

const mode = (p) => statSync(p).mode & 0o777

test("saveConfigScript writes 0600 in a 0700 dir, leaves no temp file, reads back", () => sandbox(home => {
  const dir = join(home, ".config", "omarchy plex") // a space in the path
  mkdirSync(join(home, ".config"))
  const r = sh(Io.saveConfigScript, [dir], { input: "http://h:32400\tTOKEN_abc-123.x\tinternal\n", home })
  assert.equal(r.code, 0, r.err)
  assert.equal(mode(dir), 0o700)
  assert.equal(mode(join(dir, "config.json")), 0o600)
  assert.deepEqual(readdirSync(dir), ["config.json"], "temp file renamed away")
  const back = sh(Io.readConfigScript, [dir], { home })
  assert.deepEqual(JSON.parse(back.out), { server: "http://h:32400", token: "TOKEN_abc-123.x", backend: "internal" })
}))

test("a symlinked config directory is refused for both read and write", () => sandbox(home => {
  const real = join(home, "elsewhere")
  mkdirSync(real)
  writeFileSync(join(real, "config.json"), '{"planted":1}')
  mkdirSync(join(home, ".config"))
  const link = join(home, ".config", "omarchy-plex")
  symlinkSync(real, link)
  assert.equal(sh(Io.readConfigScript, [link], { home }).out, "")
  const w = sh(Io.saveConfigScript, [link], { input: "http://h:32400\ttok_0123456789\tmpv\n", home })
  assert.notEqual(w.code, 0)
  assert.equal(readFileSync(join(real, "config.json"), "utf8"), '{"planted":1}', "nothing written through the link")
  assert.deepEqual(readdirSync(real), ["config.json"])
}))

test("a hostile directory name is data, not code", () => sandbox(home => {
  const marker = join(home, "pwned")
  // Relative `touch pwned` (sh runs with cwd = home): a slash in the name
  // would just make the parent directory missing, proving nothing.
  const dir = join(home, "x'; touch pwned; '$(touch pwned)`touch pwned`")
  sh(Io.saveStateScript, [dir, "14", "14", "460", "true", "60", "0"], { home })
  sh(Io.readStateScript, [dir], { home })
  assert.equal(existsSync(marker), false)
  assert.equal(existsSync(join(dir, "window.json")), true, "the odd name is just a directory")
}))

test("saveStateScript round-trips window.json as numbers and a boolean", () => sandbox(home => {
  const dir = join(home, "state", "omarchy-plex")
  mkdirSync(join(home, "state"))
  assert.equal(sh(Io.saveStateScript, [dir, "20", "30", "640", "false", "125", "8000"], { home }).code, 0)
  assert.equal(mode(join(dir, "window.json")), 0o600)
  assert.deepEqual(readdirSync(dir), ["window.json"])
  const doc = JSON.parse(sh(Io.readStateScript, [dir], { home }).out)
  assert.deepEqual(doc, { right: 20, bottom: 30, width: 640, windowed: false, volume: 125, quality: 8000 })
}))

test("state read caps at 1025 bytes and refuses a symlinked window.json", () => sandbox(home => {
  const dir = join(home, "s")
  mkdirSync(dir)
  writeFileSync(join(dir, "window.json"), Buffer.alloc(3000, 65))
  assert.equal(sh(Io.readStateScript, [dir], { home }).out.length, 1025)
  rmSync(join(dir, "window.json"))
  symlinkSync("/etc/passwd", join(dir, "window.json"))
  assert.equal(sh(Io.readStateScript, [dir], { home }).out, "")
}))

test("mpvQuitScript is a silent no-op with no socket, even at an odd path", () => sandbox(home => {
  const r = sh(Io.mpvQuitScript, [join(home, "no such'sock")], { home })
  assert.equal(r.code, 0)
  assert.equal(r.out + r.err, "")
}))

test("home cache scripts round-trip arbitrary titles through stdin, 0600, no temp left", () => sandbox(home => {
  const dir = join(home, ".cache", "omarchy-plex")
  mkdirSync(join(home, ".cache"))
  const body = JSON.stringify({ v: 1, server: "http://h:32400", title: "it's \"$(touch pwned)\" `x`" })
  const r = sh(Io.saveHomeCacheScript, [dir], { input: body, home })
  assert.equal(r.code, 0, r.err)
  assert.equal(mode(dir), 0o700)
  assert.equal(mode(join(dir, "home.json")), 0o600)
  assert.deepEqual(readdirSync(dir), ["home.json"])
  assert.ok(!existsSync(join(home, "pwned")))
  assert.equal(sh(Io.readHomeCacheScript, [dir], { home }).out, body)
}))

test("home cache write is capped one byte over the read ceiling", () => sandbox(home => {
  const dir = join(home, ".cache", "omarchy-plex")
  mkdirSync(join(home, ".cache"))
  const r = sh(Io.saveHomeCacheScript, [dir], { input: "A".repeat(300000), home })
  assert.equal(r.code, 0, r.err)
  assert.equal(statSync(join(dir, "home.json")).size, 262145)
}))

test("home cache read refuses a symlinked file and a missing dir", () => sandbox(home => {
  const dir = join(home, ".cache", "omarchy-plex")
  assert.equal(sh(Io.readHomeCacheScript, [dir], { home }).out, "")
  mkdirSync(dir, { recursive: true })
  symlinkSync("/etc/passwd", join(dir, "home.json"))
  assert.equal(sh(Io.readHomeCacheScript, [dir], { home }).out, "")
}))
