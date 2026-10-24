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
  // The floaty surface is a pure PiP: video plus a whisper of controls, with
  // all browse/search/setup in the real window. Nothing on it ever needs typing
  // before the first click, and an Exclusive grab there makes every other
  // window on the desktop deaf while a miniplayer sits in the corner. OnDemand
  // only, and Exclusive must not come back by accident.
  assert.match(qml, /WlrKeyboardFocus\.OnDemand/)
  assert.doesNotMatch(qml, /WlrKeyboardFocus\.Exclusive/)
  assert.match(qml, /id: searchDebounce[\s\S]{0,300}root\.search\(searchInput\.text\)/)
})

const io = readFileSync(new URL("../Io.js", import.meta.url), "utf8")

test("config and state IO is single-open bounded and atomic", () => {
  // The scripts live in Io.js; the panel passes paths as positional args.
  const qmlio = qml + io
  assert.doesNotMatch(qml, /FileView\s*\{/)
  assert.doesNotMatch(qml, /stat -c|cat --/)
  assert.match(qmlio, /if=config\.json iflag=nofollow,nonblock bs=4097 count=1/)
  assert.match(qmlio, /if=window\.json iflag=nofollow,nonblock bs=1025 count=1/)
  assert.match(qml, /raw\.length > 4096/)
  assert.match(qml, /raw\.length > 1024/)
  assert.match(qmlio, /\.config\.\$\$\.tmp/)
  assert.match(qmlio, /\.window\.\$\$\.tmp/)
  assert.match(qmlio, /mv -f --/)
  assert.match(qml, /stdinEnabled: true/)
  assert.match(qml, /onStarted: write\(root\.server/)
  assert.doesNotMatch(qml, /OMARCHY_PLEX_TOKEN|PLEX_TOKEN=|root\.token \+ "' '/)
  assert.match(qmlio, /cd -P --/)
  assert.match(qml, /onReleased: root\.saveWidth\(\)/)
  // Nothing environment-derived is spliced into shell source any more.
  assert.doesNotMatch(qml, /"d='" \+/)
  assert.doesNotMatch(qml, /UNIX-CONNECT:'" \+/)
  for (const m of qml.matchAll(/\["sh", "-c", ([^,\]]+)/g))
    assert.match(m[1], /^Io\.\w+Script$/, "sh -c source must be a fixed Io.js script: " + m[1])
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
  // The stream stash rides the resolve response the panel already has.
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

// FFmpeg re-sends http-header-fields on every redirect hop, and extras
// (/services/iva/…) 302 to a third-party CDN. The token header must only ever
// be attached behind tokenHeaderAllowed, and both direct-play call sites must
// share one URL builder (they drifted once, over extras' `?`).
test("media token header is gated by origin and path", () => {
  const headerSites = qml.match(/X-Plex-Token: " \+ root\.token/g) || []
  // curl pool header (Plex API only), native httpHeaders, mpv argv.
  assert.equal(headerSites.length, 3)
  assert.match(qml, /mediaHeaderAllowed\(root\.currentMediaUrl\) \? \["X-Plex-Token: " \+ root\.token\] : \[\]/)
  assert.match(qml, /if \(root\.mediaHeaderAllowed\(root\.pendingMpvUrl\)\)\s*args\.push\("--http-header-fields=X-Plex-Token: "/)
  // An EDL sends the header to EVERY segment, so it may only carry it when
  // every part passed tokenHeaderAllowed; otherwise the parts play as a chain.
  const media = qml.slice(qml.indexOf("function mediaHeaderAllowed"), qml.indexOf("function streamEnded"))
  assert.match(media, /indexOf\("edl:\/\/"\) === 0\) return root\.edlActive && root\.edlHeaderSafe\(\)/)
  assert.match(media, /return root\.tokenHeaderAllowed\(u\)/)
  const safe = qml.slice(qml.indexOf("function edlHeaderSafe"), qml.indexOf("function edlUrl"))
  assert.match(safe, /if \(!root\.tokenHeaderAllowed\(root\.server \+ root\.mediaParts\[i\]\.key\)\) return false/)
  const allowed = qml.slice(qml.indexOf("function tokenHeaderAllowed"), qml.indexOf("function directPlayUrl"))
  assert.match(allowed, /path\.indexOf\("\/library\/"\) === 0 \|\| path\.indexOf\("\/video\/"\) === 0/)
  // Every (re)start goes through launchStream, which is the one place a
  // direct-play URL is built.
  assert.match(qml.slice(qml.indexOf("function launchStream"), qml.indexOf("function playSource")), /root\.directPlayUrl\(/)
  assert.doesNotMatch(qml, /root\.server \+ (partKey|root\.currentPartKey)\b/)
})

// /proc/PID/cmdline is world-readable on this box (no hidepid), so a token in
// curl's argv is a token published for the life of the request. Every curl
// reads its auth header from a `-K -` config on stdin instead; the only argv
// exception left is the external mpv backend, which cannot read headers any
// other way.
test("curl argv never carries the Plex token", () => {
  const hAt = qml.indexOf("readonly property var plexHeaders")
  const headers = qml.slice(hAt, qml.indexOf("]", hAt) + 1)
  assert.match(headers, /"-K", "-"/)
  assert.doesNotMatch(headers, /token/i)
  // Every command array that starts with curl: no token, and its Process feeds
  // the config. Commands are built as ["curl", ...].concat(...) expressions.
  const curlSites = [...qml.matchAll(/(\w+)\.command = \["curl"[\s\S]*?\n\s*\1\.running = true/g)]
  const poolSite = qml.slice(qml.indexOf("function pumpRequests"), qml.indexOf("function slotDone"))
  assert.ok(curlSites.length >= 3, "found the per-call curl sites")
  for (const [block] of [...curlSites, [poolSite]]) {
    assert.doesNotMatch(block, /root\.token/, block.slice(0, 60))
    assert.match(block, /root\.plexHeaders/, block.slice(0, 60))
  }
  // Each curl Process writes the config in onStarted.
  for (const id of ["req0", "req1", "req2", "req3", "timelinePost", "scrobblePost", "trackPut"]) {
    const at = qml.indexOf("id: " + id + "\n")
    assert.ok(at > 0, id)
    assert.match(qml.slice(at, at + 400), new RegExp("onStarted: [^\\n]*root\\.feedCurlAuth\\(" + id + "\\)"), id)
  }
  // The config line itself cannot be broken out of: validToken's alphabet has
  // no quote, backslash or newline.
  assert.match(qml, /function curlAuthConfig\(\) \{\s*return "header = \\"X-Plex-Token: " \+ root\.token \+ "\\"\\n"/)
})

test("a saved quality tier starts the item on the transcoder; track picks respect it", () => {
  const apply = qml.slice(qml.indexOf("function applyMetadata"), qml.indexOf("// ---- where the token may go"))
  assert.match(apply, /root\.triedTranscode = root\.qualityKbps > 0/)
  assert.match(qml, /function playSource\(title\) \{[\s\S]{0,120}root\.launchStream\(root\.triedTranscode,/)
  assert.match(qml.slice(qml.indexOf("function launchStream"), qml.indexOf("function playSource")),
    /root\.triedTranscode \? root\.transcodeUrl\(/)
  // A transcode carries one audio track: an ordinal off the original file
  // would select nothing on either mpv engine.
  const pick = qml.slice(qml.indexOf("function activateTrackRow"), qml.indexOf("function putTrackSelection"))
  assert.match(pick, /if \(root\.mpvMode \|\| root\.nativeMode\) \{\s*if \(needsServer \|\| root\.triedTranscode\)/)
})

test("stop and failure capture the position before the engine is torn down", () => {
  const stop = qml.slice(qml.indexOf("  function stop() {"), qml.indexOf("  function stopEngine()"))
  assert.ok(stop.indexOf("seekDisplayTime") < stop.indexOf("stopEngine()"), "capture precedes teardown")
  assert.match(stop, /finishPlayback\(t, d\)/)
  // Failures dedupe per stream generation, never by wall clock.
  assert.doesNotMatch(qml, /lastFailMs/)
  assert.match(qml, /if \(root\.failedGen === root\.playGen\) return/)
  // Positions only count once the engine has loaded THIS stream.
  assert.match(qml, /root\.nativeVideo && root\.nativeLoaded \? root\.nativeVideo\.timePos : root\.streamLocalStart/)
  assert.match(qml, /function startMpv[\s\S]{0,700}root\.mpvTime = 0\s*root\.mpvDuration = 0/)
})
