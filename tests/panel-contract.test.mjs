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

test("config and state IO is single-open bounded and atomic", () => {
  assert.doesNotMatch(qml, /FileView\s*\{/)
  assert.doesNotMatch(qml, /stat -c|cat --/)
  assert.match(qml, /if=config\.json iflag=nofollow,nonblock bs=4097 count=1/)
  assert.match(qml, /if=window\.json iflag=nofollow,nonblock bs=1025 count=1/)
  assert.match(qml, /raw\.length > 4096/)
  assert.match(qml, /raw\.length > 1024/)
  assert.match(qml, /\.config\.\$\$\.tmp/)
  assert.match(qml, /\.window\.\$\$\.tmp/)
  assert.match(qml, /mv -f --/)
  assert.match(qml, /stdinEnabled: true/)
  assert.match(qml, /onStarted: write\(root\.server/)
  assert.doesNotMatch(qml, /PLEXMINI_TOKEN|root\.token \+ "' '/)
  assert.match(qml, /cd -P --/)
  assert.match(qml, /onReleased: root\.saveWidth\(\)/)
})
