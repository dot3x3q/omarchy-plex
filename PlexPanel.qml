import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Commons
import "Model.js" as Model

// Plex Mini panel entry point.
// Hosted by omarchy-shell; summoned with:
//   omarchy-shell shell toggle io.github.joshuaswarren.plexmini
// Config lives in ~/.config/plexmini/config.json:
//   { "server": "http://host:32400", "token": "...", "backend": "internal" }
// backend "internal" (default): ytmini-style miniplayer — video renders
//   inside the floating panel with transport controls under it.
// backend "mpv" (opt-in): playback launches in a standalone mpv window,
//   pinned bottom-right (--hwdec=auto --vo=gpu-next for dGPU decode, same
//   engine as plex-mpv-shim); the panel becomes the remote over mpv's IPC.
//
// Security posture: the X-Plex-Token travels only in HTTP headers for API
// calls (never URL query — process lists, logs, and redirects leak those).
// Remote URLs are scheme-checked before reaching a player; mpv runs with
// --no-config --no-ytdl so hostile media cannot pull in scripts or extractors.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.joshuaswarren.plexmini"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/plexmini"
  // Per-session socket name inside XDG_RUNTIME_DIR (0700); random suffix so a
  // stale socket from a crashed instance is never reused.
  readonly property string sockId: {
    var d = new Date()
    return "plexmini-" + d.getTime().toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36)
  }
  readonly property string ipcSock: (Quickshell.env("XDG_RUNTIME_DIR")
    || ("/run/user/" + (Quickshell.env("UID") || "1000"))) + "/" + sockId + ".sock"
  readonly property color background: Color.background
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: foreground

  property int videoWidth: 460
  readonly property int videoHeight: Math.round(videoWidth * 9 / 16)
  function tint(a) { return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, a) }

  // ---- config ----
  property string server: ""
  property string token: ""
  property string backend: "internal"

  FileView {
    id: configFile
    path: root.configDir + "/config.json"
    watchChanges: false
    onLoaded: {
      try {
        var doc = JSON.parse(text())
        var s = String(doc.server || "")
        var t = String(doc.token || "")
        // Only accept well-formed persisted values; anything else re-runs setup.
        if (Model.validServer(s)) root.server = s
        if (Model.validToken(t)) root.token = t
        if (doc.backend === "mpv") root.backend = "mpv"
      } catch (e) { /* first run */ }
    }
  }

  function saveConfig() {
    // Validate visibly instead of silently mangling; nothing user-controlled
    // is ever interpolated into shell source.
    if (!Model.validServer(root.server)) {
      fail("Server must look like http://host:32400")
      return false
    }
    if (!Model.validToken(root.token)) {
      fail("Token looks wrong — Plex tokens are letters/digits, 20ish chars")
      return false
    }
    saveProcess.running = true
    return true
  }

  Process {
    id: saveProcess
    running: false
    command: ["sh", "-c",
      "mkdir -p '" + root.configDir + "' && chmod 700 '" + root.configDir + "'"
      + " && umask 077 && printf '{\"server\":\"%s\",\"token\":\"%s\",\"backend\":\"%s\"}' "
      + "'" + root.server + "' '" + root.token + "' "
      + "'" + (root.backend === "internal" ? "internal" : "mpv") + "'"
      + " > '" + root.configDir + "/config.json'"]
  }

  Component.onCompleted: {
    configFile.reload()
    positionFile.reload()
  }

  function configured() { return root.server !== "" && root.token !== "" }

  // ---- state ----
  property bool opened: false
  property string mode: "setup" // setup | list | playing | error
  property string statusText: ""
  property var items: [] // [{ title, sub, ratingKey }]
  property string currentTitle: ""

  // session / progress-reporting state
  property string currentRatingKey: ""
  property string sessionId: ""
  property bool triedTranscode: false
  property bool userStop: false
  property bool scrobbled: false
  property int tickCount: 0
  property int resumeSec: 0
  property int playGen: 0 // guards mpv exit handler against item switches

  // mpv remote state (seconds)
  property real mpvTime: 0
  property real mpvDuration: 0
  property bool mpvPaused: false

  // ---- window position (drag header; persisted) ----
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/plexmini"
  property int marginRight: 14
  property int marginBottom: 14

  function clampMargins() {
    var w = window && window.screen ? window.screen.width : 0
    var h = window && window.screen ? window.screen.height : 0
    if (w > 0) root.marginRight = Math.max(0, Math.min(root.marginRight, w - window.width))
    if (h > 0) root.marginBottom = Math.max(0, Math.min(root.marginBottom, h - window.height))
  }

  function saveWidth() {
    posSave.width = "" + root.videoWidth
    posSave.running = true
  }

  function savePosition() {
    posSave.right = "" + Math.round(root.marginRight)
    posSave.bottom = "" + Math.round(root.marginBottom)
    posSave.running = true
  }

  Process {
    id: posSave
    property string right: "14"
    property string bottom: "14"
    property string width: "460"
    running: false
    command: ["sh", "-c",
      "mkdir -p '" + root.stateDir + "' && printf '{\"right\":%s,\"bottom\":%s,\"width\":%s}' "
      + posSave.right + " " + posSave.bottom + " " + posSave.width
      + " > '" + root.stateDir + "/window.json'"]
  }

  FileView {
    id: positionFile
    path: root.stateDir + "/window.json"
    watchChanges: false
    onLoaded: {
      try {
        var doc = JSON.parse(text())
        if (doc.right !== undefined) root.marginRight = Math.max(0, doc.right | 0)
        if (doc.bottom !== undefined) root.marginBottom = Math.max(0, doc.bottom | 0)
        if (doc.width !== undefined) root.videoWidth = Math.max(280, Math.min(900, doc.width | 0))
      } catch (e) { /* keep defaults */ }
    }
  }

  // First-party lock service: never map over the lock screen.
  property var lockService: null
  readonly property bool sessionLocked: lockService !== null && lockService.locked === true

  // Unlike the radio, a video player pauses when the session locks and
  // resumes when it unlocks.
  property bool wasPlayingBeforeLock: false
  onSessionLockedChanged: {
    if (root.mode !== "playing") return
    if (root.sessionLocked) {
      root.wasPlayingBeforeLock = !root.mpvPaused && (root.backend === "mpv"
        || player.playbackState === MediaPlayer.PlayingState)
      if (root.backend === "mpv") mpvSend('{"command":["set_property","pause",true]}')
      else player.pause()
    } else if (root.wasPlayingBeforeLock) {
      if (root.backend === "mpv") mpvSend('{"command":["set_property","pause",false]}')
      else player.play()
    }
  }
  Timer {
    id: lockServiceResolve
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (root.lockService !== null) { lockServiceResolve.stop(); return }
      if (root.shell && typeof root.shell.serviceFor === "function") {
        var ls = root.shell.serviceFor("omarchy.lock")
        if (ls !== null && ls !== undefined) root.lockService = ls
      }
    }
  }

  // ---- lifecycle ----
  function open() {
    root.opened = true
    if (!configured()) { root.mode = "setup"; return }
    if (window.visible) keyHost.forceActiveFocus()
    if (root.items.length === 0) loadOnDeck()
  }

  function close() {
    // Plex is video, not radio: hiding the miniplayer must never leave audio
    // running in the background. Pause, then hide; reopening stays paused.
    if (root.mode === "playing") {
      if (root.backend === "mpv") {
        mpvSend('{"command":["set_property","pause",true]}')
        root.mpvPaused = true
      } else {
        player.pause()
      }
      sendTimeline("paused")
    }
    root.opened = false
  }

  // ---- Plex API ----
  // Token travels as a header, never a URL query: query strings leak via
  // process lists, server logs, and cross-host redirects. No redirect
  // following: Plex does not redirect API calls, and following one would
  // forward credentials.
  function apiUrl(path) {
    return root.server + path
  }

  readonly property var plexHeaders: [
    "-H", "Accept: application/json",
    "-H", "X-Plex-Token: " + root.token,
    "-H", "X-Plex-Client-Identifier: io.github.joshuaswarren.plexmini"
  ]

  function loadOnDeck() {
    apiFetch.op = "onDeck"
    apiFetch.command = ["curl", "-s", "--fail", "--max-time", "10"]
      .concat(root.plexHeaders)
      .concat([apiUrl("/library/onDeck")])
    apiFetch.running = true
  }

  function search(q) {
    if (q.trim() === "") { loadOnDeck(); return }
    apiFetch.op = "search"
    apiFetch.command = ["curl", "-s", "--fail", "--max-time", "10"]
      .concat(root.plexHeaders)
      .concat([apiUrl("/search?query=" + encodeURIComponent(q.trim()))])
    apiFetch.running = true
  }

  // Resolve the media part, then hand the URL to the backend. Direct play
  // first; universal transcode HLS is the fallback when a codec fails.
  function playItem(ratingKey, title) {
    resolve.ratingKey = ratingKey
    resolve.title = title
    resolve.command = ["curl", "-s", "--fail", "--max-time", "10"]
      .concat(root.plexHeaders)
      .concat([apiUrl("/library/metadata/" + ratingKey)])
    resolve.running = true
  }

  function applyMetadata(jsonText) {
    try {
      var md = JSON.parse(jsonText).MediaContainer.Metadata[0]
      var partKey = String(md.Media[0].Part[0].key || "")
      // Server-derived value: must be an absolute Plex library path.
      if (partKey.indexOf("/") !== 0) { fail("No playable part found"); return }
      root.currentRatingKey = String(resolve.ratingKey)
      root.sessionId = "" + Date.now()
      root.triedTranscode = false
      root.userStop = false
      root.scrobbled = false
      root.tickCount = 0
      root.resumeSec = Math.round((md.viewOffset || 0) / 1000)
      var mediaUrl = root.server + partKey
      if (root.backend !== "mpv") mediaUrl += "?X-Plex-Token=" + root.token
      playSource(mediaUrl, resolve.title)
    } catch (e) {
      fail("Could not resolve media")
    }
  }

  function applyList(jsonText, op) {
    try {
      var out = Model.mapItems(JSON.parse(jsonText).MediaContainer, op)
      root.items = out
      root.mode = "list"
      root.statusText = op === "search" && out.length === 0 ? "No results" : ""
    } catch (e) {
      fail("Plex request failed — check server URL and token")
    }
  }

  function fail(msg) {
    root.mode = "error"
    root.statusText = msg
  }

  function playSource(url, title) {
    root.currentTitle = title
    root.playGen++
    if (root.backend === "mpv") startMpv(url)
    else startInternal(url)
    pollTimer.restart()
  }

  // ---- mpv backend ----
  function startMpv(url) {
    // One mpv at a time owns the IPC socket: quit any previous instance,
    // wait out the socket release, then launch.
    root.mode = "playing"
    mpvQuit.running = true
    mpvStarter.url = url
    mpvStarter.gen = root.playGen
    mpvRelay.restart()
  }

  Timer {
    id: mpvRelay
    interval: 300
    repeat: false
    onTriggered: {
      // Fixed args, validated URL; --no-config drops user scripts/hooks and
      // --no-ytdl prevents extractor spawning on attacker-chosen URLs.
      // Residual risk, accepted for a single-user desktop: the token header
      // is visible in mpv's argv (/proc/PID/cmdline). mpv cannot read
      // headers from a file; rotating the token closes any exposure window.
      var sw = window && window.screen ? Math.round(window.screen.width) : 1920
      var sh = window && window.screen ? Math.round(window.screen.height) : 1080
      mpvProc.command = ["mpv",
        "--no-config", "--no-ytdl",
        "--hwdec=auto", "--vo=gpu-next",
        "--really-quiet", "--keep-open=no",
        "--start=" + Math.max(0, root.resumeSec) + ".5",
        "--input-ipc-server=" + root.ipcSock,
        "--http-header-fields=X-Plex-Token: " + root.token,
        // bottom-right miniplayer placement instead of centre-screen
        "--autofit=" + root.videoWidth + "x" + root.videoHeight,
        "--geometry=-" + (root.marginRight + 14) + "-" + (root.marginBottom + 130),
        mpvStarter.url]
      root.resumeSec = 0
      mpvProc.gen = mpvStarter.gen
      mpvProc.running = true
    }
  }

  Process {
    id: mpvProc
    property int gen: 0
    running: false
    onExited: function(exitCode) {
      // A newer playSource supersedes this exit; ignore it.
      if (mpvProc.gen !== root.playGen || root.backend !== "mpv") return
      if (root.mode !== "playing") return
      pollTimer.stop()
      if (root.userStop || exitCode === 0) {
        finishPlayback()
        return
      }
      // mpv choked on the codec — fall back to server transcode.
      playbackFailed()
    }
  }
  Process {
    id: mpvQuit
    running: false
    command: ["sh", "-c",
      "test -S '" + root.ipcSock + "' && echo '{\"command\":[\"quit\"]}' | socat - UNIX-CONNECT:'" + root.ipcSock + "' >/dev/null 2>&1 || true"]
  }

  Process {
    id: mpvStarter
    property string url: ""
    property int gen: 0
    running: false
  }

  function mpvSend(payload) {
    // Command fully built BEFORE running (Quickshell ignores later writes).
    // Payloads here are fixed JSON templates plus numbers only.
    mpvCtl.command = ["sh", "-c",
      "echo '" + payload.replace(/'/g, "") + "' | socat - UNIX-CONNECT:'" + root.ipcSock + "'"]
    mpvCtl.running = true
  }

  Process {
    id: mpvCtl
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Newline-delimited JSON-IPC: one reply per line, request_id tags
        // which property each numeric reply describes.
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trim() === "") continue
          try {
            var r = JSON.parse(lines[i])
            if (r.error || !("data" in r)) continue
            if (r.request_id === 0 && typeof r.data === "number") root.mpvTime = r.data
            else if (r.request_id === 1 && typeof r.data === "number") root.mpvDuration = r.data
            else if (typeof r.data === "boolean") root.mpvPaused = r.data
          } catch (e) { /* non-json line */ }
        }
      }
    }
  }
  // Poll playback position/state while playing. Every 10s the tick also
  // reports a timeline update; crossing 90% scrobbles once.
  Timer {
    id: pollTimer
    interval: 1000
    repeat: true
    triggeredOnStart: false
    onTriggered: {
      root.tickCount++
      if (root.backend === "mpv" && root.mode === "playing") {
        mpvSend('{"command":["get_property","time-pos"],"request_id":0}\n{"command":["get_property","duration"],"request_id":1}\n{"command":["get_property","pause"],"request_id":2}')
      }
      if (root.dispDuration > 0 && !root.scrobbled
          && root.dispTime / root.dispDuration >= 0.9) {
        root.scrobbled = true
        sendScrobble()
      }
      if (root.tickCount % 10 === 0)
        sendTimeline(root.mpvPaused ? "paused" : "playing")
    }
  }

  function togglePause() {
    if (root.backend === "mpv") mpvSend('{"command":["cycle","pause"]}')
    else if (player.playbackState === MediaPlayer.PlayingState) player.pause()
    else player.play()
  }

  function seekRel(seconds) {
    if (root.backend === "mpv") mpvSend('{"command":["seek",' + seconds + ']}')
    else player.position = Math.max(0, player.position + seconds * 1000)
  }

  function seekAbs(fraction) {
    if (root.backend !== "mpv" || root.dispDuration <= 0) return
    mpvSend('{"command":["set_property","time-pos",' + (fraction * root.dispDuration).toFixed(1) + ']}')
  }
  // ---- keyboard navigation ----
  // Up/Down move a selection through the results, Enter plays it, Space
  // toggles pause, Left/Right seek, Escape hides. The search field shares
  // the arrows and Enter with the list, launcher-style.
  function moveSel(delta) {
    var n = resultList.count
    if (n === 0 || root.mode !== "list") return
    var i = resultList.currentIndex
    if (i < 0) i = delta > 0 ? 0 : n - 1
    else i = ((i + delta) % n + n) % n
    resultList.currentIndex = i
    resultList.positionViewAtIndex(i, ListView.Contain)
  }

  function playSel() {
    if (root.mode !== "list") return
    if (resultList.currentIndex >= 0 && resultList.currentIndex < root.items.length)
      root.playItem(root.items[resultList.currentIndex].ratingKey,
                    root.items[resultList.currentIndex].title)
  }

  function finishPlayback() {
    sendTimeline("stopped")
    pollTimer.stop()
    root.mode = "list"
    root.currentTitle = ""
  }

  function stop() {
    root.userStop = true
    if (root.backend === "mpv") {
      mpvQuit.running = true
      finishPlayback()
    } else {
      player.stop()
      player.source = ""
      finishPlayback()
    }
  }

  // ---- internal backend (fallback) ----
  function startInternal(url) {
    player.stop()
    if (typeof videoOut !== "undefined" && videoOut !== null) player.videoOutput = videoOut
    player.source = url
    root.mode = "playing"
    root.statusText = ""
    player.play()
  }

  // Network media can report LoadedMedia before it is seekable. Retry the
  // resume seek until the player reports it actually reached the offset.
  Timer {
    id: resumeRetry
    interval: 250
    repeat: true
    onTriggered: {
      if (root.resumeSec <= 0 || root.mode !== "playing") { stop(); return }
      var target = root.resumeSec * 1000
      if (player.position >= target - 1000) { root.resumeSec = 0; stop(); return }
      player.position = target
    }
  }

  MediaPlayer {
    id: player
    // videoOutput is assigned in startInternal(): the surface lives inside
    // the PanelWindow, whose children do not exist until the panel is shown,
    // so binding it here throws ReferenceError on load.
    audioOutput: AudioOutput {
      id: audio
      volume: 0.6
    }
    onMediaStatusChanged: function(status) {
      if (status === MediaPlayer.LoadedMedia && root.resumeSec > 0) {
        player.position = root.resumeSec * 1000
        resumeRetry.restart()
      }
      if (status === MediaPlayer.EndOfMedia) finishPlayback()
      else if (status === MediaPlayer.InvalidMedia) playbackFailed()
    }
    onErrorOccurred: function(error) {
      playbackFailed()
    }
  }

  // ---- server transcode fallback + progress reporting ----
  function transcodeUrl() {
    // Universal transcode HLS: server re-encodes, player plays the playlist.
    // Token stays in the query because HLS players fetch segments themselves;
    // the URL exists only inside this machine's mpv/player process.
    return apiUrl("/video/:/transcode/universal/start.m3u8"
      + "?Path=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
      + "&mediaIndex=0&partIndex=0&protocol=hls"
      + "&directPlay=0&directStream=0&hasMDE=1"
      + "&videoQuality=60&maxVideoBitrate=6000&audioBoost=100&subtitleSize=100"
      + "&session=" + root.sessionId
      + "&X-Plex-Token=" + root.token
      + "&X-Plex-Product=Plex%20Mini&X-Plex-Client-Identifier=io.github.joshuaswarren.plexmini")
  }

  function playbackFailed() {
    if (root.triedTranscode || root.currentRatingKey === "") {
      fail("Direct play and transcode both failed")
      return
    }
    root.triedTranscode = true
    root.statusText = "Direct play failed — transcoding…"
    var url = transcodeUrl()
    root.playGen++
    if (root.backend === "mpv") startMpv(url)
    else startInternal(url)
  }

  function sendTimeline(state) {
    if (root.currentRatingKey === "") return
    timelinePost.command = ["curl", "-s", "--fail", "--max-time", "5", "-o", "/dev/null"]
      .concat(root.plexHeaders)
      .concat([apiUrl("/:/timeline?ratingKey=" + root.currentRatingKey
        + "&key=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
        + "&duration=" + Math.round(root.dispDuration * 1000)
        + "&time=" + Math.round(root.dispTime * 1000)
        + "&state=" + state
        + "&hasMDE=1&identifier=com.plexapp.plugins.library"
        + "&X-Plex-Client-Identifier=io.github.joshuaswarren.plexmini"
        + "&X-Plex-Product=Plex%20Mini&X-Plex-Device-Name=PlexMini")])
    timelinePost.running = true
  }

  function sendScrobble() {
    if (root.currentRatingKey === "") return
    scrobblePost.command = ["curl", "-s", "--fail", "--max-time", "5", "-o", "/dev/null"]
      .concat(root.plexHeaders)
      .concat([apiUrl("/:/scrobble?key=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
        + "&identifier=com.plexapp.plugins.library")])
    scrobblePost.running = true
  }

  Process {
    id: timelinePost
    running: false
  }

  Process {
    id: scrobblePost
    running: false
  }

  // ---- API response processes (command set before running) ----
  Process {
    id: apiFetch
    property string op: "onDeck"
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyList(String(text || ""), apiFetch.op)
    }
  }

  Process {
    id: resolve
    property string ratingKey: ""
    property string title: ""
    running: false
    onStarted: root.currentTitle = title
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyMetadata(String(text || ""))
    }
  }

  // ---- display helpers ----
  readonly property bool mpvMode: root.backend === "mpv" && root.mode === "playing"
  readonly property real dispTime: mpvMode ? root.mpvTime : player.position / 1000
  readonly property real dispDuration: mpvMode ? root.mpvDuration : player.duration / 1000



  // ---- window ----
  PanelWindow {
    id: window
    visible: root.opened && !root.sessionLocked
    anchors { top: false; left: false; right: true; bottom: true }
    margins { right: root.marginRight; bottom: root.marginBottom }
    implicitWidth: root.videoWidth
    implicitHeight: root.mode === "playing"
      ? (root.backend === "mpv" ? root.videoHeight * 0.45 : root.videoHeight) + 92
      : 380
    onWidthChanged: root.clampMargins()
    onHeightChanged: root.clampMargins()
    color: root.background
    WlrLayershell.namespace: "plexmini"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Keyboard host. PanelWindow cannot carry a Keys attachment (it is not
    // an Item — the shell logs "Could not attach Keys"), so every shortcut
    // lives here and this Item owns focus whenever the search field does not.
    //   Space pause · Left/Right seek · Up/Down select · Enter play
    //   PgUp/PgDn page the list · Esc hide · M mute (internal backend)
    Item {
      id: keyHost
      width: 0; height: 0
      focus: true

      Keys.onSpacePressed: function(event) { event.accepted = true; root.togglePause() }
      Keys.onLeftPressed: function(event) { event.accepted = true; root.seekRel(-30) }
      Keys.onRightPressed: function(event) { event.accepted = true; root.seekRel(30) }
      Keys.onUpPressed: function(event) { event.accepted = true; root.moveSel(-1) }
      Keys.onDownPressed: function(event) { event.accepted = true; root.moveSel(1) }
      // PageUp/PageDown/M have no attached-signal form; catch them here.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_PageUp) { event.accepted = true; root.moveSel(-8) }
        else if (event.key === Qt.Key_PageDown) { event.accepted = true; root.moveSel(8) }
        else if (event.key === Qt.Key_M && !root.mpvMode) { event.accepted = true; audio.muted = !audio.muted }
      }
      Keys.onReturnPressed: function(event) { event.accepted = true; root.playSel() }
      Keys.onEnterPressed: function(event) { event.accepted = true; root.playSel() }
      Keys.onEscapePressed: function(event) { event.accepted = true; root.close() }
    }

    onVisibleChanged: if (visible) keyHost.forceActiveFocus()

      // resize grip — thin strip on the panel's left edge, inside bounds.
      // Dragging left grows the miniwindow; width persists across restarts.
      MouseArea {
        id: resizeGrip
        anchors.left: parent.left
        anchors.top: parent.top
        width: 28
        height: 28
        z: 100
        cursorShape: Qt.SizeFDiagCursor
        property int sx: 0
        property int startW: 0
        onPressed: function(mouse) { sx = mapToItem(null, mouse.x, mouse.y).x; startW = root.videoWidth }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var gx = mapToItem(null, mouse.x, mouse.y).x
          root.videoWidth = Math.max(280, Math.min(900, startW + (sx - gx)))
          root.saveWidth()
        }
      }
    Column {
      anchors.fill: parent
      anchors.margins: 1
      spacing: 0

      // header
      Rectangle {
        width: parent.width
        height: 34
        color: root.background

        MouseArea {
          id: headerDrag
          anchors.fill: parent
          cursorShape: Qt.SizeAllCursor
          property int sx: 0
          property int sy: 0
          property int sr: 0
          property int sb: 0
          onPressed: function(mouse) { sx = mouse.x; sy = mouse.y; sr = root.marginRight; sb = root.marginBottom }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            root.marginRight = sr - (mouse.x - sx)
            root.marginBottom = sb - (mouse.y - sy)
            root.clampMargins()
          }
          onReleased: root.savePosition()
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 100
          elide: Text.ElideRight
          textFormat: Text.PlainText
          color: root.mode === "error" ? root.urgent : root.foreground
          text: {
            if (root.mode === "error") return root.statusText
            if (root.mode === "playing") return root.currentTitle + (root.mpvMode && root.mpvPaused ? " (paused)" : "")
            if (root.mode === "setup") return "Plex Mini — server setup"
            return root.statusText !== "" ? root.statusText : "Continue Watching"
          }
          font.pixelSize: 13
          font.family: Style.fontFamily
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 18

          Text {
            visible: root.mode === "playing" || root.mode === "list"
            color: root.foreground
            opacity: root.mode === "playing" ? 1 : 0.4
            text: (root.mpvMode ? root.mpvPaused : player.playbackState === MediaPlayer.PausedState) ? "󰐊" : "󰏤"
            font.pixelSize: 15
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.togglePause()
            }
          }

          Text {
            color: root.foreground
            text: "󰅖"
            font.pixelSize: 16
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: root.accent; opacity: 0.35 }


      // setup form
      Column {
        width: parent.width
        height: root.mode === "setup" ? 200 : 0
        visible: height > 0
        spacing: 8
        topPadding: 12

        Repeater {
          model: [
            { field: "server", placeholder: "Server URL e.g. http://192.168.1.50:32400" },
            { field: "token", placeholder: "X-Plex-Token (app.plex.tv URL or plex.tv/api/devices)" }
          ]
          delegate: Rectangle {
            required property var modelData
            width: parent.width - 20
            x: 10
            height: 32
            radius: Style.cornerRadius
            color: root.background
            border.color: input.activeFocus ? root.accent : root.muted
            border.width: 1
            opacity: 0.9

            TextInput {
              id: input
              anchors.fill: parent
              anchors.margins: 8
              color: root.foreground
              selectionColor: root.accent
              echoMode: modelData.field === "token" ? TextInput.Password : TextInput.Normal
              font.pixelSize: 12
              font.family: Style.fontFamily
              clip: true
              verticalAlignment: TextInput.AlignVCenter
              // One-way seed only: writing back through onTextChanged caused
              // a binding loop that corrupted typed URLs mid-keystroke.
              text: modelData.field === "server" ? root.server : root.token
              onTextEdited: {
                if (modelData.field === "server") root.server = text.trim()
                else root.token = text.trim()
              }
              onAccepted: {
                if (modelData.field === "server") root.server = text.trim().replace(/\/+$/, "")
                if (root.saveConfig()) root.loadOnDeck()
              }

              Text {
                visible: input.text === "" && !input.activeFocus
                anchors.fill: parent
                anchors.margins: 8
                verticalAlignment: Text.AlignVCenter
                color: root.muted
                opacity: 0.6
                font.pixelSize: 12
                font.family: Style.fontFamily
                text: modelData.placeholder
              }
            }
          }
        }

        Text {
          x: 12
          color: root.muted
          opacity: 0.7
          font.pixelSize: 11
          font.family: Style.fontFamily
          text: "Enter saves · stored chmod 600 in ~/.config/plexmini · backend: " + root.backend
        }

        Rectangle {
          width: 90
          height: 28
          x: 10
          radius: Style.cornerRadius
          color: mouseSave.containsPress ? root.accent : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)

          Behavior on opacity { NumberAnimation { duration: 120 } }

          Text {
            anchors.centerIn: parent
            color: root.foreground
            font.pixelSize: 12
            font.family: Style.fontFamily
            text: "Connect"
          }
          MouseArea {
            id: mouseSave
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.saveConfig()) { root.loadOnDeck(); keyHost.forceActiveFocus() }
            }
          }
        }
      }

      // search bar (list mode)
      Rectangle {
        width: parent.width - 24
        x: 12
        height: root.mode === "list" || root.mode === "error" ? 30 : 0
        visible: height > 0
        radius: Style.cornerRadius
        color: root.background
        border.color: searchInput.activeFocus ? root.accent : root.muted
        border.width: 1
        opacity: 0.9

        TextInput {
          id: searchInput
          anchors.fill: parent
          anchors.margins: 7
          color: root.foreground
          selectionColor: root.accent
          font.pixelSize: 12
          font.family: Style.fontFamily
          clip: true
          verticalAlignment: TextInput.AlignVCenter
          onAccepted: root.search(text)
          Keys.onEscapePressed: { if (text !== "") text = ""; else root.close() }
          Keys.onUpPressed: function(event) { event.accepted = true; root.moveSel(-1) }
          Keys.onDownPressed: function(event) { event.accepted = true; root.moveSel(1) }
          // Keys handlers consume the key before TextInput's keyPressEvent,
          // so onAccepted would never fire: play a selection if one exists,
          // otherwise treat Enter as "run this search".
          Keys.onReturnPressed: function(event) {
            event.accepted = true
            if (resultList.currentIndex >= 0 && resultList.currentIndex < root.items.length) root.playSel()
            else if (text.trim() !== "") root.search(text)
          }
          Keys.onEnterPressed: function(event) {
            event.accepted = true
            if (resultList.currentIndex >= 0 && resultList.currentIndex < root.items.length) root.playSel()
            else if (text.trim() !== "") root.search(text)
          }
          Keys.onTabPressed: function(event) { event.accepted = true; keyHost.forceActiveFocus() }

          Text {
            visible: searchInput.text === "" && !searchInput.activeFocus
            anchors.fill: parent
            anchors.margins: 7
            verticalAlignment: Text.AlignVCenter
            color: root.muted
            opacity: 0.6
            font.pixelSize: 12
            font.family: Style.fontFamily
            text: "Search your library and press Enter…"
          }
        }
      }
      ListView {
        id: resultList
        width: parent.width
        height: root.mode !== "playing"
          ? Math.max(0, window.height - 34 - 1 - (searchInput.visible ? 30 : 0) - 14)
          : 0
        visible: height > 0
        focus: true
        Keys.onUpPressed: function(event) { event.accepted = true; root.moveSel(-1) }
        Keys.onDownPressed: function(event) { event.accepted = true; root.moveSel(1) }
        Keys.onReturnPressed: function(event) { event.accepted = true; root.playSel() }
        Keys.onEnterPressed: function(event) { event.accepted = true; root.playSel() }
        Keys.onSpacePressed: function(event) { event.accepted = true; root.togglePause() }
        Keys.onEscapePressed: root.close()
        Keys.onLeftPressed: function(event) { if (root.mode === "playing") { event.accepted = true; root.seekRel(-30) } }
        Keys.onRightPressed: function(event) { if (root.mode === "playing") { event.accepted = true; root.seekRel(30) } }
        clip: true
        spacing: 2
        model: root.items
        currentIndex: -1
        keyNavigationEnabled: false // window-level handlers own the keys
        delegate: Rectangle {
          id: resultRow
          required property var modelData
          required property int index
          readonly property bool selected: ListView.isCurrentItem
          width: ListView.view.width - 24
          height: 44
          x: 12
          radius: Style.cornerRadius
          color: rowMouse.containsPress ? root.tint(0.28)
            : (resultRow.selected ? root.tint(0.16)
              : (rowMouse.containsMouse ? root.tint(0.15) : "transparent"))
          Behavior on color { ColorAnimation { duration: 100 } }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            spacing: 1
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              color: root.foreground
              font.pixelSize: 13
              font.family: Style.fontFamily
              text: modelData.title
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              visible: modelData.sub !== ""
              textFormat: Text.PlainText
              color: root.muted
              opacity: 0.55
              font.pixelSize: 11
              font.family: Style.fontFamily
              text: modelData.sub
            }
          }
          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.playItem(modelData.ratingKey, modelData.title)
          }
        }
      }

      // video surface — internal backend renders in-panel; mpv uses its own
      // window, so this collapses to zero height in mpv mode.
      Item {
        width: parent.width
        height: root.mode === "playing" && root.backend === "internal" ? root.videoHeight : 0

        VideoOutput {
          id: videoOut
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
        }
      }
      // mpv status plate (mpv renders in its own window)
      Item {
        width: parent.width
        height: root.mode === "playing" && root.backend === "mpv" ? root.videoHeight * 0.45 : 0
        Text {
          anchors.centerIn: parent
          color: root.muted
          opacity: 0.5
          font.pixelSize: 12
          font.family: Style.fontFamily
          text: root.triedTranscode ? "Playing via server transcode" : "Playing in mpv (hardware decode)"
        }
      }

      // controls (playing)
      Item {
        width: parent.width
        height: root.mode === "playing" ? 56 : 0
        visible: height > 0

        Rectangle {
          id: seekBar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          height: 7
          radius: 3
          color: root.muted
          opacity: 0.25

          Rectangle {
            width: root.dispDuration > 0 ? parent.width * (root.dispTime / root.dispDuration) : 0
            height: parent.height
            radius: 3
            color: root.accent

            Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuad } }
          }

          MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
              if (width > 0) root.seekAbs(mouse.x / width)
            }
          }
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.top: seekBar.bottom
          anchors.topMargin: 9
          color: root.muted
          font.pixelSize: 13
          font.family: Style.fontFamily
          text: Model.fmtDuration(root.dispTime) + " / " + Model.fmtDuration(root.dispDuration)
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.top: seekBar.bottom
          anchors.topMargin: 4
          spacing: 14

          Item {
            width: 36
            height: 30
            Text {
              anchors.centerIn: parent
              color: root.foreground
              font.pixelSize: 20
              font.family: Style.fontFamily
              text: "󰒮"
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.seekRel(-30)
              }
            }
          }

          Item {
            width: 36
            height: 30
            Text {
              anchors.centerIn: parent
              color: root.foreground
              font.pixelSize: 20
              font.family: Style.fontFamily
              text: "󰒭"
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.seekRel(30)
              }
            }
          }

          Item {
            width: 36
            height: 30
            Text {
              anchors.centerIn: parent
              color: audio.muted && !root.mpvMode ? root.urgent : root.foreground
              font.pixelSize: 22
              font.family: Style.fontFamily
              text: audio.muted && !root.mpvMode ? "󰖁" : "󰕾"
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (!root.mpvMode) audio.muted = !audio.muted
              }
            }
          }

          Item {
            width: 36
            height: 30
            Text {
              anchors.centerIn: parent
              color: root.urgent
              font.pixelSize: 22
              font.family: Style.fontFamily
              text: "󰓛"
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.stop()
              }
            }
          }
        }
      }
    }
  }
}
