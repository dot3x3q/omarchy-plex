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
  // Wave 4 turned the floaty surface into a pure PiP: video plus a whisper of
  // controls, with all browse/search/setup living in the real window. Nothing
  // on that surface ever needs typing before the first click, so the Exclusive
  // grab this used to pin — which made every other window on the desktop deaf
  // while a miniplayer sat in the corner — has no remaining justification.
  // OnDemand only, and Exclusive must not come back by accident.
  assert.match(qml, /WlrKeyboardFocus\.OnDemand/)
  assert.doesNotMatch(qml, /WlrKeyboardFocus\.Exclusive/)
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

const theater = readFileSync(new URL("../TheaterView.qml", import.meta.url), "utf8")

test("PiP screen handoff happens on RELEASE, never mid-drag", () => {
  // Reassigning PanelWindow.screen destroys the layer surface (Quickshell
  // implements it as hide -> setScreen -> show, and WlrLayershell forces
  // deleteOnInvisible), and that surface is what holds Wayland's implicit
  // pointer grab. Doing it from onPositionChanged would delete the grab owner
  // mid-gesture and strand the card. The drag handler may move margins; only
  // the release handler may move the window.
  const drag = qml.slice(qml.indexOf("id: pipDrag"), qml.indexOf("id: resizeGrip"))
  assert.match(drag, /onReleased: function\(mouse\)[\s\S]{0,400}root\.handlePipDrop\(/)
  const motion = drag.slice(drag.indexOf("onPositionChanged"), drag.indexOf("onReleased"))
  assert.doesNotMatch(motion, /window\.screen\s*=/)
  assert.doesNotMatch(motion, /commitPipScreen|cyclePipScreen/)
  // Entering the PiP adopts the real window's output, which is half the
  // multi-monitor fix on its own.
  assert.match(qml, /function enterPip\(\)[\s\S]{0,1200}var host = appWindow\.screen/)
  // Clamp and snap measure the SCREEN, not the surface: right after a handoff
  // window.width still describes the output we just left.
  assert.match(qml, /function clampMargins\(\)[\s\S]{0,200}root\.pipAreaWidth/)
  assert.match(qml, /function snapPip\(\)[\s\S]{0,200}root\.pipAreaWidth/)
})

test("track selection reaches the server before any transcode restart", () => {
  // The server builds a transcode from whatever is selected on the part, so a
  // restart that raced the PUT would re-mux the OLD tracks. The restart hangs
  // off the PUT process's exit for that reason.
  // Slice the trackPut Process block rather than budgeting characters, so
  // adding to it does not break the pin that guards it.
  const putBlock = qml.slice(qml.indexOf("id: trackPut"), qml.indexOf("function beginTrackRestart"))
  assert.match(putBlock, /onExited:[\s\S]*root\.beginTrackRestart\(\)/)
  // ...and the restart must not be reachable any other way from a pick.
  const pick = qml.slice(qml.indexOf("function activateTrackRow"), qml.indexOf("function putTrackSelection"))
  assert.doesNotMatch(pick, /beginTrackRestart/)
  assert.match(qml, /"-X", "PUT"/)
  // Token stays in headers — partSelectionUrl must never carry it.
  assert.match(qml, /trackPut\.command = \[[\s\S]{0,300}concat\(root\.plexHeaders\)/)
  assert.doesNotMatch(qml, /partSelectionUrl\([^)]*token/)
  // The stream stash rides the resolve response we already have, and the
  // frozen Model call above it is untouched.
  assert.match(qml, /root\.currentThumbPath = root\.metadataThumb\(jsonText\)\s*\n\s*root\.stashStreams\(jsonText\)/)
})

test("an open track picker owns the keyboard before Esc's layered walk", () => {
  // Popup first, THEN theater, then the back-stack, then arm-close. If this
  // ordering inverts, Esc leaves theater with the list still on screen.
  const body = qml.slice(qml.indexOf("function handleKey(event)"), qml.indexOf("// ---- floaty surface"))
  const popupAt = body.indexOf("root.handleTrackPopupKey")
  const escAt = body.indexOf("root.escapePressed()")
  assert.ok(popupAt > 0 && escAt > 0, "both handlers present")
  assert.ok(popupAt < escAt, "popup key handling must precede escapePressed")
  // The pickers are theater-only; the PiP strip is far too small for them.
  assert.match(qml, /root\.windowed && !ctrl && !alt && key === Qt\.Key_A/)
  assert.doesNotMatch(theater, /audioPickerAvailable[\s\S]{0,80}pipStrip/)
})
