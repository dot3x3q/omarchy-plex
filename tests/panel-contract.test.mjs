import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
const qml = readFileSync(new URL("../PlexPanel.qml", import.meta.url), "utf8")

test("panel contract pins integration chokepoints", () => {
  assert.match(qml, /--max-filesize", "4194304"/)
  assert.match(qml, /Model\.parsePlaybackMetadata\(jsonText\)/)
  assert.match(qml, /resumeRetry[\s\S]{0,600}player\.position = target/)
  const closeBody = qml.slice(qml.indexOf("function close()"), qml.indexOf("function playSource"))
  assert.match(closeBody, /player\.playbackState === MediaPlayer\.PlayingState\)[\s\S]*player\.pause\(\)/)
  assert.match(qml, /WlrKeyboardFocus\.Exclusive/)
  assert.match(qml, /id: searchDebounce[\s\S]{0,300}root\.search\(searchInput\.text\)/)
})
