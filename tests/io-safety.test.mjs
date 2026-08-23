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
  const dir = mkdtempSync(join(tmpdir(), "plexmini-io-"))
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
