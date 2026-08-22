import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
const qml = readFileSync(new URL("../PlexPanel.qml", import.meta.url), "utf8")

test("panel contract pins integration chokepoints", () => {
  assert.match(qml, /--max-filesize", "4194304"/)
  assert.match(qml, /Model\.parsePlaybackMetadata\(jsonText\)/)
  assert.match(qml, /resultRow[\s\S]{0,300}height: 44/)
  assert.match(qml, /resumeRetry[\s\S]{0,600}player\.position = target/)
  assert.match(qml, /function close\(\)[\s\S]{0,500}player\.pause\(\)/)
  assert.match(qml, /WlrKeyboardFocus\.Exclusive/)
  assert.match(qml, /id: searchDebounce[\s\S]{0,300}root\.search\(searchInput\.text\)/)
})

test("resize grip is outside the main Column", () => {
  const grip = qml.indexOf("id: resizeGrip")
  const column = qml.indexOf("Column {", grip)
  assert.ok(grip > 0 && column > grip, "grip must precede main Column")
})
