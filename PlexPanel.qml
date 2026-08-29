import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Api.js" as Api

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
// The window draws no chrome of its own: Hyprland owns the frame, the drag
// and the resize, so an in-app title bar would only duplicate the compositor
// and steal 34px from every screen. What the old header did lives on as the
// status banner, the header row's actions, and the window `title:` property
// that Hyprland's rules still match on.
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
  readonly property color muted: Color.muted
  readonly property string fontFamily: Style.font.family

  property int videoWidth: 460
  readonly property int videoHeight: Math.round(videoWidth * 9 / 16)
  function tint(a) { return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, a) }

  // ---- config ----
  property string server: ""
  property string token: ""
  property string backend: "internal"

  // Single bounded open: symlinks fail O_NOFOLLOW, FIFOs/devices cannot
  // block under O_NONBLOCK, and the 4097th byte makes JS reject oversize.
  Process {
    id: configRead
    running: false
    command: ["sh", "-c",
      "d='" + root.configDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
      + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
      + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& dd if=config.json iflag=nofollow,nonblock bs=4097 count=1 status=none 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var raw = String(text || "")
          if (raw.length > 4096) return
          var doc = JSON.parse(raw)
          var s = String(doc.server || "")
          var t = String(doc.token || "")
          if (Model.validServer(s)) root.server = s
          if (Model.validToken(t)) root.token = t
          if (doc.backend === "mpv") root.backend = "mpv"
        } catch (e) { /* first run or rejected file */ }
      }
    }
  }

  function saveConfig() {
    // Validate visibly instead of silently mangling; nothing user-controlled
    // is ever interpolated into shell source.
    if (!Model.validServer(root.server)) {
      root.setStatus("Server must look like http://host:32400", true)
      return false
    }
    if (!Model.validToken(root.token)) {
      root.setStatus("Token looks wrong — Plex tokens are letters/digits, 20ish chars", true)
      return false
    }
    root.setStatus("", false)
    saveProcess.running = true
    return true
  }

  Process {
    id: saveProcess
    running: false
    // Secrets travel through the process stdin pipe, never argv, shell
    // source, or world-readable cmdline. Pin cwd to the canonical directory
    // inode, then write/rename relative names so a path swap cannot redirect.
    stdinEnabled: true
    onStarted: write(root.server + "\t" + root.token + "\t"
      + (root.backend === "internal" ? "internal" : "mpv") + "\n")
    command: ["sh", "-c",
      "IFS=$(printf '\t') read -r plex_server plex_token plex_backend || exit 1; "
      + "d='" + root.configDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
      + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
      + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& umask 077 && t=.config.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
      + "&& printf '{\"server\":\"%s\",\"token\":\"%s\",\"backend\":\"%s\"}' "
      + "\"$plex_server\" \"$plex_token\" \"$plex_backend\" > \"$t\" "
      + "&& chmod 600 \"$t\" && mv -f -- \"$t\" config.json && trap - EXIT"]
  }

  Component.onCompleted: {
    configRead.running = true
    positionRead.running = true
  }

  function configured() { return root.server !== "" && root.token !== "" }

  // Settings page calls this once saveConfig() has accepted the form.
  function configApplied() {
    root.mode = "list"
    root.setStatus("", false)
    root.loadLibraries()
    root.navigate("home", ({}))
    keyHost.forceActiveFocus()
  }

  // ---- state ----
  property bool opened: false
  property string mode: "setup" // setup | list | playing | error
  property string statusText: ""
  property bool statusUrgent: false
  property string currentTitle: ""

  // Video libraries from /library/sections: [{ id, title, type }].
  property var libraries: []
  // Wave-2 pages read this; the root fills it so the debounced search box
  // keeps working before SearchPage is real.
  property var searchResults: []

  function setStatus(msg, urgent) {
    root.statusText = msg === undefined || msg === null ? "" : String(msg)
    root.statusUrgent = urgent === true
  }

  // session / progress-reporting state
  property string currentRatingKey: ""
  property string sessionId: ""
  property bool triedTranscode: false
  property real lastFailMs: 0
  property bool userStop: false
  property bool scrobbled: false
  property int tickCount: 0
  property int resumeSec: 0
  property int playGen: 0 // guards mpv exit handler against item switches
  property string pendingMpvUrl: "" // staged for mpvRelay's 300 ms socket-release wait

  // mpv remote state (seconds)
  property real mpvTime: 0
  property real mpvDuration: 0
  property bool mpvPaused: false

  // ---- navigation ----
  // navStack holds where we came FROM; the live location is currentPage.
  property var navStack: []
  property string currentPage: "home"
  property var pageParams: ({})
  readonly property int navStackLimit: 32

  function navigate(page, params) {
    var next = String(page || "home")
    var args = params === undefined || params === null ? ({}) : params
    if (next === root.currentPage) {
      // Same page, new arguments: replace rather than stack a history entry,
      // or every debounced keystroke in the search box becomes a back step.
      root.pageParams = args
      return
    }
    var stack = root.navStack.slice()
    stack.push({ page: root.currentPage, params: root.pageParams })
    while (stack.length > root.navStackLimit) stack.shift()
    root.navStack = stack
    root.currentPage = next
    root.pageParams = args
    root.setPanelCursor("page", "")
  }

  function goBack() {
    if (root.navStack.length === 0) {
      if (root.currentPage !== "home") {
        root.currentPage = "home"
        root.pageParams = ({})
        root.setPanelCursor("page", "")
      }
      return
    }
    var stack = root.navStack.slice()
    var prev = stack.pop()
    root.navStack = stack
    root.currentPage = String(prev.page || "home")
    root.pageParams = prev.params === undefined || prev.params === null ? ({}) : prev.params
    root.setPanelCursor("page", "")
  }

  // ---- scroll memory (LRU, bounded) ----
  // Pages hand back their contentY on teardown and ask for it again on load,
  // so drilling into a detail page and coming back lands where you left.
  property var scrollPositions: ({})
  property var scrollOrder: []
  readonly property int scrollLimit: 64

  function rememberScroll(key, y) {
    var name = String(key || root.currentPage)
    if (name === "") return
    var order = Array.isArray(root.scrollOrder) ? root.scrollOrder.slice() : []
    var store = root.scrollPositions && typeof root.scrollPositions === "object"
      ? root.scrollPositions : ({})
    var at = order.indexOf(name)
    if (at >= 0) order.splice(at, 1)
    order.push(name)
    store[name] = Math.max(0, Number(y) || 0)
    while (order.length > root.scrollLimit) {
      var dropped = String(order.shift() || "")
      if (dropped !== "") delete store[dropped]
    }
    root.scrollOrder = order
    root.scrollPositions = store
  }

  function scrollFor(key) {
    var name = String(key || root.currentPage)
    if (!root.scrollPositions || typeof root.scrollPositions !== "object") return 0
    return Math.max(0, Number(root.scrollPositions[name]) || 0)
  }

  // ---- panel cursor ----
  // Exactly one highlight exists at a time and mouse and keyboard share it:
  // controls read cursorOn(region, action) and write setPanelCursor() on
  // hover, so the keyboard cursor follows the pointer instead of fighting it.
  // Regions: "sidebar" | "search" | "page" | "playing".
  property string cursorRegion: "page"
  property string cursorAction: ""

  function setPanelCursor(region, action) {
    root.cursorRegion = region === undefined || region === null ? "" : String(region)
    root.cursorAction = action === undefined || action === null ? "" : String(action)
  }

  function cursorOn(region, action) {
    return root.cursorRegion === String(region)
      && root.cursorAction === String(action === undefined || action === null ? "" : action)
  }

  // ---- window position (persisted) ----
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/plexmini"
  property int marginRight: 14
  property int marginBottom: 14
  // Primary surface: a real toplevel window the compositor tiles like any
  // app. The layer-shell panel remains as the secondary "floaty" mode.
  property bool windowed: true

  function toggleSurface() {
    root.windowed = !root.windowed
    root.savePosition()
  }

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
    posSave.windowed = root.windowed ? "true" : "false"
    posSave.running = true
  }

  Process {
    id: posSave
    property string right: "14"
    property string bottom: "14"
    property string width: "460"
    property string windowed: "true"
    running: false
    command: ["sh", "-c",
      "d='" + root.stateDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
      + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
      + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& umask 077 && t=.window.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
      + "&& printf '{\"right\":%s,\"bottom\":%s,\"width\":%s,\"windowed\":%s}' "
      + posSave.right + " " + posSave.bottom + " " + posSave.width + " " + posSave.windowed
      + " > \"$t\" && chmod 600 \"$t\" && mv -f -- \"$t\" window.json && trap - EXIT"]
  }

  // Bounded regular-file state read: no symlinks or special files; 1 KiB max.
  Process {
    id: positionRead
    running: false
    command: ["sh", "-c",
      "d='" + root.stateDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
      + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
      + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& dd if=window.json iflag=nofollow,nonblock bs=1025 count=1 status=none 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var raw = String(text || "")
          if (raw.length > 1024) return
          var doc = JSON.parse(raw)
          if (doc.right !== undefined) root.marginRight = Math.max(0, doc.right | 0)
          if (doc.bottom !== undefined) root.marginBottom = Math.max(0, doc.bottom | 0)
          if (doc.width !== undefined) root.videoWidth = Math.max(280, Math.min(900, doc.width | 0))
          if (doc.windowed !== undefined) root.windowed = doc.windowed === true
        } catch (e) { /* keep defaults */ }
      }
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
  function focusPrimary() {
    // Defer until the mode's UI is visible; typing should search immediately.
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.mode === "list" || root.mode === "error") searchInput.forceActiveFocus()
      else keyHost.forceActiveFocus()
    })
  }

  function open() {
    root.opened = true
    if (!configured()) { root.mode = "setup"; root.focusPrimary(); return }
    // A hidden panel can still hold a live playback session; returning to
    // the player beats orphaning audio behind a list.
    if (root.mode !== "playing") {
      root.mode = "list"
      if (root.libraries.length === 0) loadLibraries()
    }
    root.focusPrimary()
  }

  function close() {
    // Plex is video, not radio: hiding the miniplayer must never leave audio
    // running in the background. Pause, then hide; reopening stays paused.
    // Guard on real playback state, not mode: mode can lag the player when
    // the panel was reopened mid-session.
    if (root.backend === "mpv") {
      if (root.mode === "playing") {
        mpvSend('{"command":["set_property","pause",true]}')
        root.mpvPaused = true
      }
    } else if (player.playbackState === MediaPlayer.PlayingState) {
      player.pause()
    }
    if (root.mode === "playing") sendTimeline("paused")
    root.opened = false
  }

  // ---- Plex API ----
  // Token travels as a header, never a URL query: query strings leak via
  // process lists, server logs, and cross-host redirects. No redirect
  // following: Plex does not redirect API calls, and following one would
  // forward credentials.

  readonly property var plexHeaders: [
    "-H", "Accept: application/json",
    "-H", "X-Plex-Token: " + root.token,
    "-H", "X-Plex-Client-Identifier: " + root.pluginId
  ]

  // Four curl slots and a FIFO queue. A home page fans out one request per
  // library, and an unbounded fan-out would have the server rate-limiting us
  // and the process table churning; four in flight keeps it civil and still
  // saturates a LAN Plex.
  property var reqQueue: []
  readonly property var reqSlots: [req0, req1, req2, req3]

  function request(path, cb) {
    if (!root.configured()) { if (cb) cb(null); return }
    var queue = root.reqQueue.slice()
    queue.push({ path: String(path || ""), cb: cb })
    root.reqQueue = queue
    root.pumpRequests()
  }

  function pumpRequests() {
    for (var i = 0; i < root.reqSlots.length; i++) {
      if (root.reqQueue.length === 0) return
      var slot = root.reqSlots[i]
      if (slot.busy) continue
      var queue = root.reqQueue.slice()
      var job = queue.shift()
      root.reqQueue = queue
      slot.busy = true
      slot.streamDone = false
      slot.exitDone = false
      slot.body = ""
      slot.cb = job.cb
      // Command fully set BEFORE running: Quickshell latches argv at start
      // and silently ignores writes to a running Process.
      slot.command = ["curl", "-s", "--fail", "--max-time", "10", "--max-filesize", "4194304"]
        .concat(root.plexHeaders)
        .concat([root.server + job.path])
      slot.running = true
    }
  }

  // A slot frees up only once BOTH its stdout stream has ended and the
  // process has exited. Quickshell emits streamFinished when the child closes
  // stdout, which can happen before it actually exits — handing that slot a
  // new command right then would have it silently dropped and the queue would
  // wedge with jobs that never run.
  function slotSettled(slot) {
    if (!slot.streamDone || !slot.exitDone) return
    var cb = slot.cb
    var body = slot.body
    slot.cb = null
    slot.body = ""
    slot.busy = false
    if (cb) {
      var parsed = null
      // --fail leaves stdout empty on any HTTP error, so a parse failure and
      // a transport failure land in the same place: cb(null).
      try { parsed = JSON.parse(String(body || "")) } catch (e) { parsed = null }
      cb(parsed)
    }
    root.pumpRequests()
  }

  Process {
    id: req0
    property var cb: null
    property string body: ""
    property bool busy: false
    property bool streamDone: false
    property bool exitDone: false
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { req0.body = String(text || ""); req0.streamDone = true; root.slotSettled(req0) }
    }
    onExited: { req0.exitDone = true; root.slotSettled(req0) }
  }
  Process {
    id: req1
    property var cb: null
    property string body: ""
    property bool busy: false
    property bool streamDone: false
    property bool exitDone: false
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { req1.body = String(text || ""); req1.streamDone = true; root.slotSettled(req1) }
    }
    onExited: { req1.exitDone = true; root.slotSettled(req1) }
  }
  Process {
    id: req2
    property var cb: null
    property string body: ""
    property bool busy: false
    property bool streamDone: false
    property bool exitDone: false
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { req2.body = String(text || ""); req2.streamDone = true; root.slotSettled(req2) }
    }
    onExited: { req2.exitDone = true; root.slotSettled(req2) }
  }
  Process {
    id: req3
    property var cb: null
    property string body: ""
    property bool busy: false
    property bool streamDone: false
    property bool exitDone: false
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { req3.body = String(text || ""); req3.streamDone = true; root.slotSettled(req3) }
    }
    onExited: { req3.exitDone = true; root.slotSettled(req3) }
  }

  // Artwork is the one documented exception to headers-only auth: QML's Image
  // cannot send an X-Plex-Token header, so it has to ride the query string.
  // These URLs must never be logged.
  function imageUrl(path, w, h) {
    if (!root.configured()) return ""
    return Api.imageUrl(root.server, root.token, path, Math.max(1, Math.round(w)), Math.max(1, Math.round(h)))
  }

  // Movies + TV only (DESIGN.md content scope) — Api.mapSections filters out
  // the server's artist-type sections (Music, Audiobooks live in the Spotify
  // app's lane, not here).
  function loadLibraries() {
    root.request(Api.sectionsUrl(""), function(doc) {
      var out = []
      try { out = Api.mapSections(doc) } catch (e) { /* leave the sidebar at Home + Settings */ }
      root.libraries = out
    })
  }

  function libraryTitle(id) {
    for (var i = 0; i < root.libraries.length; i++)
      if (root.libraries[i].id === String(id)) return String(root.libraries[i].title)
    return "Library"
  }

  function libraryType(id) {
    for (var i = 0; i < root.libraries.length; i++)
      if (root.libraries[i].id === String(id)) return String(root.libraries[i].type)
    return ""
  }

  Timer {
    id: searchDebounce
    interval: 300
    repeat: false
    onTriggered: if (root.opened && root.configured()) root.search(searchInput.text)
  }

  // Guards searchResults against out-of-order responses: with four pooled
  // slots, a slow response for "jo" can land after the fast one for "john
  // wick" and silently replace the newer results.
  property int searchGen: 0

  function search(q) {
    var query = String(q === undefined || q === null ? "" : q).trim()
    root.searchGen++
    if (query === "") {
      root.searchResults = []
      if (root.currentPage === "search") root.goBack()
      return
    }
    var gen = root.searchGen
    root.navigate("search", { query: query })
    root.request(Api.searchUrl("", query), function(doc) {
      if (gen !== root.searchGen) return
      var out = []
      try { out = Api.mapSearch(doc) } catch (e) { out = [] }
      root.searchResults = out
      root.setStatus(out.length === 0 ? "No results for “" + query + "”" : "", false)
    })
  }

  function refresh() {
    if (!root.configured()) return
    root.loadLibraries()
    var item = pageLoader.item
    if (item && typeof item.reload === "function") item.reload()
  }

  // Resolve the media part, then hand the URL to the backend. Direct play
  // first; universal transcode HLS is the fallback when a codec fails.
  function playItem(ratingKey, title) {
    resolve.ratingKey = ratingKey
    resolve.title = title
    resolve.command = ["curl", "-s", "--fail", "--max-time", "10", "--max-filesize", "2097152"]
      .concat(root.plexHeaders)
      .concat([root.server + "/library/metadata/" + ratingKey])
    resolve.running = true
  }

  function applyMetadata(jsonText) {
    try {
      var parsed = Model.parsePlaybackMetadata(jsonText)
      if (!parsed) { fail("No playable part found"); return }
      var partKey = parsed.partKey
      root.currentRatingKey = String(resolve.ratingKey)
      root.sessionId = "" + Date.now()
      root.triedTranscode = false
      root.userStop = false
      root.scrobbled = false
      root.tickCount = 0
      root.resumeSec = parsed.viewOffsetSec
      var mediaUrl = root.server + partKey
      if (root.backend !== "mpv") mediaUrl += "?X-Plex-Token=" + root.token
      playSource(mediaUrl, resolve.title)
    } catch (e) {
      fail("Could not resolve media")
    }
  }

  function fail(msg) {
    pollTimer.stop()
    root.mode = "error"
    root.setStatus(msg, true)
  }

  function playSource(url, title) {
    root.currentTitle = title
    root.playGen++
    if (root.backend === "mpv") startMpv(url)
    else startInternal(url)
    pollTimer.restart()
    // The search field hides with the browse pane; transport keys need a home.
    keyHost.forceActiveFocus()
    root.setPanelCursor("playing", "play")
  }

  // ---- mpv backend ----
  function startMpv(url) {
    // One mpv at a time owns the IPC socket: quit any previous instance,
    // wait out the socket release, then launch.
    root.mode = "playing"
    mpvQuit.running = true
    root.pendingMpvUrl = url
    mpvRelay.restart()
  }

  Timer {
    id: mpvRelay
    interval: 300
    repeat: false
    onTriggered: {
      // The old process can outlive its socket quit for more than 300 ms;
      // defer instead of dropping the replacement launch.
      if (mpvProc.running) { restart(); return }
      // Fixed args, validated URL; --no-config drops user scripts/hooks and
      // --no-ytdl prevents extractor spawning on attacker-chosen URLs.
      // Residual risk, accepted for a single-user desktop: the token header
      // is visible in mpv's argv (/proc/PID/cmdline). mpv cannot read
      // headers from a file; rotating the token closes any exposure window.
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
        root.pendingMpvUrl]
      root.resumeSec = 0
      mpvProc.gen = root.playGen
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
      if (root.tickCount % 10 === 0) {
        var paused = root.backend === "mpv"
          ? root.mpvPaused
          : player.playbackState === MediaPlayer.PausedState
        sendTimeline(paused ? "paused" : "playing")
      }
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
    if (root.backend === "mpv") {
      if (root.dispDuration <= 0) return
      mpvSend('{"command":["set_property","time-pos",' + (fraction * root.dispDuration).toFixed(1) + ']}')
    } else if (player.duration > 0) {
      player.position = Math.max(0, Math.min(player.duration, fraction * player.duration))
    }
  }

  function finishPlayback() {
    sendTimeline("stopped")
    pollTimer.stop()
    root.mode = "list"
    root.currentTitle = ""
    root.setPanelCursor("page", "")
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
    root.setStatus("", false)
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
    return root.server + "/video/:/transcode/universal/start.m3u8"
      + "?Path=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
      + "&mediaIndex=0&partIndex=0&protocol=hls"
      + "&directPlay=0&directStream=0&hasMDE=1"
      + "&videoQuality=60&maxVideoBitrate=6000&audioBoost=100&subtitleSize=100"
      + "&session=" + root.sessionId
      + "&X-Plex-Token=" + root.token
      + "&X-Plex-Product=Plex%20Mini&X-Plex-Client-Identifier=" + root.pluginId
  }

  function playbackFailed() {
    var now = Date.now()
    if (now - root.lastFailMs < 250) return
    root.lastFailMs = now
    if (root.triedTranscode || root.currentRatingKey === "") {
      fail("Direct play and transcode both failed")
      return
    }
    root.triedTranscode = true
    root.setStatus("Direct play failed — transcoding…", false)
    var url = transcodeUrl()
    root.playGen++
    if (root.backend === "mpv") startMpv(url)
    else startInternal(url)
  }

  function sendTimeline(state) {
    if (root.currentRatingKey === "") return
    timelinePost.command = ["curl", "-s", "--fail", "--max-time", "5", "-o", "/dev/null"]
      .concat(root.plexHeaders)
        .concat([root.server + "/:/timeline?ratingKey=" + root.currentRatingKey
        + "&key=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
        + "&duration=" + Math.round(root.dispDuration * 1000)
        + "&time=" + Math.round(root.dispTime * 1000)
        + "&state=" + state
        + "&hasMDE=1&identifier=com.plexapp.plugins.library"
        + "&X-Plex-Client-Identifier=" + root.pluginId
        + "&X-Plex-Product=Plex%20Mini&X-Plex-Device-Name=PlexMini"])
    timelinePost.running = true
  }

  function sendScrobble() {
    if (root.currentRatingKey === "") return
    scrobblePost.command = ["curl", "-s", "--fail", "--max-time", "5", "-o", "/dev/null"]
      .concat(root.plexHeaders)
        .concat([root.server + "/:/scrobble?key=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
        + "&identifier=com.plexapp.plugins.library"])
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
  readonly property bool isPaused: root.mpvMode
    ? root.mpvPaused : player.playbackState !== MediaPlayer.PlayingState

  // ---- page routing ----
  function pageComponent() {
    if (root.mode === "setup" || root.currentPage === "settings") return settingsPageComponent
    if (root.currentPage === "search") return searchPageComponent
    if (root.currentPage === "library") return libraryPageComponent
    if (root.currentPage === "detail") return detailPageComponent
    return homePageComponent
  }

  function pageTitle() {
    if (root.mode === "setup") return "Set up Plex Mini"
    if (root.currentPage === "settings") return "Settings"
    if (root.currentPage === "search") return "Search"
    if (root.currentPage === "library") return root.libraryTitle(root.pageParams.sectionId)
    if (root.currentPage === "detail") return String(root.pageParams.title || "Details")
    return "Continue Watching"
  }

  function pageSubtitle() {
    if (root.mode === "setup") return "Point this at your Plex server to get started"
    if (root.currentPage === "settings") return "Server, token and playback backend"
    if (root.currentPage === "search") {
      var q = String(root.pageParams.query || "")
      return q === "" ? "Movies and TV across your whole server" : "Results for “" + q + "”"
    }
    if (root.currentPage === "library")
      return root.libraryType(root.pageParams.sectionId) === "show" ? "TV shows" : "Movies"
    if (root.currentPage === "detail") return String(root.pageParams.subtitle || "")
    return "Pick up where you left off"
  }

  Component { id: homePageComponent; HomePage { panel: root } }
  Component { id: searchPageComponent; SearchPage { panel: root } }
  Component { id: libraryPageComponent; LibraryPage { panel: root } }
  Component { id: detailPageComponent; DetailPage { panel: root } }
  Component { id: settingsPageComponent; SettingsPage { panel: root } }

  // ---- sidebar model ----
  // Actions are strings so the cursor can name one without an index:
  // "home", "lib:<sectionId>", "settings".
  readonly property var sidebarActions: {
    var a = ["home"]
    for (var i = 0; i < root.libraries.length; i++) a.push("lib:" + root.libraries[i].id)
    a.push("settings")
    return a
  }

  function activateSidebar(action) {
    var a = String(action || "")
    if (a === "home") { root.navigate("home", ({})); return }
    if (a === "settings") { root.navigate("settings", ({})); return }
    if (a.indexOf("lib:") === 0) {
      var id = a.substring(4)
      root.navigate("library", { sectionId: id })
    }
  }

  // ---- keyboard ----
  // The root FocusScope is the fallback handler, not the first one: Qt sends
  // a key to the focused item and only bubbles it up here if that item did
  // not accept it. That is exactly the gate the design asks for — a focused
  // text field swallows letters, "/" and Left/Right on its own, so h/j/k/l
  // and the single-letter shortcuts below cannot fire while you are typing,
  // while Up/Down/Tab/Esc (which a single-line field ignores) still reach us.
  property bool escapeCloseArmed: false

  Timer {
    id: escapeCloseTimer
    interval: 1500
    repeat: false
    onTriggered: root.escapeCloseArmed = false
  }

  function armEscapeClose() {
    root.escapeCloseArmed = true
    escapeCloseTimer.restart()
  }

  function disarmEscapeClose() {
    escapeCloseTimer.stop()
    root.escapeCloseArmed = false
  }

  function escapePressed() {
    if (searchInput.activeFocus && searchInput.text !== "") {
      searchInput.text = ""
      root.disarmEscapeClose()
      return
    }
    if (searchInput.activeFocus) {
      keyHost.forceActiveFocus()
      root.setPanelCursor("page", "")
      return
    }
    if (root.mode !== "playing" && root.navStack.length > 0) {
      root.disarmEscapeClose()
      root.goBack()
      return
    }
    if (root.escapeCloseArmed) {
      root.disarmEscapeClose()
      root.close()
      return
    }
    root.armEscapeClose()
  }

  function focusSearch() {
    if (!searchInput.visible) return
    searchInput.selectAll()
    searchInput.forceActiveFocus()
    root.setPanelCursor("search", "input")
  }

  function cycleRegion(dir) {
    var order = ["search", "page", "sidebar"]
    var at = order.indexOf(root.cursorRegion)
    if (at < 0) at = 0
    at = ((at + dir) % order.length + order.length) % order.length
    // Skip the search box when it is not on screen (setup, playing).
    if (order[at] === "search" && !searchInput.visible)
      at = ((at + dir) % order.length + order.length) % order.length
    root.enterRegion(order[at])
  }

  function enterRegion(region) {
    if (region === "search") { root.focusSearch(); return }
    keyHost.forceActiveFocus()
    if (region === "sidebar") {
      var actions = root.sidebarActions
      var action = actions.indexOf(root.cursorAction) >= 0 ? root.cursorAction : actions[0]
      root.setPanelCursor("sidebar", action)
      return
    }
    root.setPanelCursor("page", "")
  }

  function moveCursor(dx, dy) {
    if (root.cursorRegion === "sidebar") {
      if (dx > 0) { root.enterRegion("page"); return }
      if (dy === 0) return
      var actions = root.sidebarActions
      var at = actions.indexOf(root.cursorAction)
      if (at < 0) at = 0
      else at = ((at + dy) % actions.length + actions.length) % actions.length
      root.setPanelCursor("sidebar", actions[at])
      return
    }
    if (root.cursorRegion === "search") {
      if (dy > 0) root.enterRegion("page")
      return
    }
    // "page" — the page owns its own geometry, so it decides what a step means.
    var item = pageLoader.item
    if (item && typeof item.moveCursor === "function") item.moveCursor(dx, dy)
  }

  function activateCursor() {
    if (root.cursorRegion === "sidebar") { root.activateSidebar(root.cursorAction); return }
    if (root.cursorRegion === "search") { root.search(searchInput.text); return }
    var item = pageLoader.item
    if (item && typeof item.activateCursor === "function") item.activateCursor()
  }

  function pageStep(dir) {
    var item = pageLoader.item
    if (!item) return
    if (dir < 0 && typeof item.pageUp === "function") item.pageUp()
    else if (dir > 0 && typeof item.pageDown === "function") item.pageDown()
  }

  // Enter from the search field: drill into whatever the page has selected if
  // anything is, otherwise treat Enter as "run this search now".
  function searchAccepted() {
    if (root.cursorRegion === "page") {
      var item = pageLoader.item
      if (item && typeof item.activateCursor === "function") { item.activateCursor(); return }
    }
    root.search(searchInput.text)
  }

  function handlePlayingKey(event, ctrl, shift, alt) {
    var key = event.key
    if (key === Qt.Key_Space) { root.togglePause(); return true }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) { root.togglePause(); return true }
    if (!ctrl && !alt && (key === Qt.Key_Left || key === Qt.Key_Right)) {
      root.seekRel((key === Qt.Key_Left ? -1 : 1) * (shift ? 30 : 10))
      return true
    }
    if (!ctrl && !alt && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      if (!root.mpvMode) audio.volume = Math.max(0, Math.min(1, audio.volume + (key === Qt.Key_Up ? 0.05 : -0.05)))
      return true
    }
    if (!ctrl && !alt && key === Qt.Key_M) {
      if (!root.mpvMode) audio.muted = !audio.muted
      return true
    }
    return false
  }

  function handleKey(event) {
    var key = event.key
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var text = String(event.text || "").toLowerCase()

    if (key === Qt.Key_Escape) { root.escapePressed(); return true }

    // Alt+Left is what every other app on this desktop uses for Back.
    if (alt && key === Qt.Key_Left) { root.goBack(); return true }

    if (root.mode === "playing") return root.handlePlayingKey(event, ctrl, shift, alt)

    if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      root.cycleRegion(shift || key === Qt.Key_Backtab ? -1 : 1)
      return true
    }

    if (!ctrl && !alt && (key === Qt.Key_Slash || text === "/")) { root.focusSearch(); return true }

    var dy = (key === Qt.Key_Up || text === "k") ? -1 : ((key === Qt.Key_Down || text === "j") ? 1 : 0)
    var dx = (key === Qt.Key_Left || text === "h") ? -1 : ((key === Qt.Key_Right || text === "l") ? 1 : 0)
    if (!ctrl && !alt && (dx !== 0 || dy !== 0)) { root.moveCursor(dx, dy); return true }

    if (key === Qt.Key_Return || key === Qt.Key_Enter) { root.activateCursor(); return true }
    if (key === Qt.Key_PageUp) { root.pageStep(-1); return true }
    if (key === Qt.Key_PageDown) { root.pageStep(1); return true }
    if (!ctrl && !alt && text === "r") { root.refresh(); return true }
    return false
  }

  // ---- window ----
  PanelWindow {
    id: window
    visible: root.opened && !root.windowed && !root.sessionLocked
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
    // A launcher-style picker must receive typing immediately on open;
    // OnDemand does not request Wayland keyboard focus until a mouse click.
    // But holding Exclusive for the panel's whole lifetime makes every other
    // window deaf while a miniplayer sits in the corner. Grab exclusively
    // only in the transient browse/setup modes; during playback drop to
    // OnDemand so the desktop stays usable — clicking the panel re-arms the
    // playback keys (Space, arrows), clicking any window gives it back.
    WlrLayershell.keyboardFocus: !root.opened ? WlrKeyboardFocus.None
      : (root.mode === "playing" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: if (visible) root.focusPrimary()

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
        onReleased: root.saveWidth()
      }

    Item { id: panelSlot; anchors.fill: parent }
  }

  // Primary surface: a real xdg-toplevel window. Hyprland tiles, swaps,
  // fullscreens, and rules it like any application window; the panel above
  // is the secondary "floaty" mode. One content tree serves both — it
  // reparents into whichever surface is active, so every id and binding in
  // this file keeps working regardless of the host.
  FloatingWindow {
    id: appWindow
    visible: root.opened && root.windowed && !root.sessionLocked
    title: root.mode === "playing" && root.currentTitle !== ""
      ? root.currentTitle + " — Plex Mini" : "Plex Mini"
    color: root.background
    implicitWidth: 960
    implicitHeight: 600
    minimumSize: Qt.size(480, 360)
    onVisibleChanged: if (visible) root.focusPrimary()

    Item { id: winSlot; anchors.fill: parent }
  }

  FocusScope {
    id: content
    parent: root.windowed ? winSlot : panelSlot
    anchors.fill: parent
    focus: true

    // Below this the sidebar drops to an icon rail; the floaty surface is
    // always narrower than this, so it gets the rail for free.
    readonly property bool compact: content.width < Style.space(760)

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }

    // Focus parking spot for when no text field should hold the caret.
    Item { id: keyHost; width: 0; height: 0 }

    // ================= browse =================
    Item {
      id: browse
      anchors.fill: parent
      anchors.margins: Style.space(14)
      visible: root.mode !== "playing"

      BorderSurface {
        id: sidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: content.compact
          ? Style.space(54)
          : Math.min(Style.space(214), Math.max(Style.space(176), browse.width * 0.225))
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, root.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

        Row {
          id: brandRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(11)
          height: Style.space(42)
          spacing: Style.space(9)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰚺"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
          }

          Column {
            visible: !content.compact
            width: Math.max(Style.space(40), parent.width - Style.space(38))
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
              width: parent.width
              text: "Plex Mini"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: root.configured() ? "Movies and TV" : "Not connected"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Column {
          id: navColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: brandRow.bottom
          anchors.margins: Style.space(8)
          spacing: Style.space(2)

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Button {
            width: parent.width
            text: content.compact ? "" : "Home"
            iconText: "󰋜"
            tooltipText: "Continue Watching"
            foreground: root.foreground
            leftAlign: !content.compact
            focusable: false
            selected: root.currentPage === "home" && root.mode !== "setup"
            hasCursor: root.cursorOn("sidebar", "home")
            onClicked: root.activateSidebar("home")
            onHovered: function(on) { if (on) root.setPanelCursor("sidebar", "home") }
          }

          Repeater {
            model: root.libraries

            Button {
              required property var modelData
              width: navColumn.width
              text: content.compact ? "" : String(modelData.title)
              iconText: modelData.type === "show" ? "󰦔" : "󰎁"
              tooltipText: String(modelData.title)
              foreground: root.foreground
              leftAlign: !content.compact
              focusable: false
              selected: root.currentPage === "library"
                && String(root.pageParams.sectionId) === String(modelData.id)
              hasCursor: root.cursorOn("sidebar", "lib:" + modelData.id)
              onClicked: root.activateSidebar("lib:" + modelData.id)
              onHovered: function(on) { if (on) root.setPanelCursor("sidebar", "lib:" + modelData.id) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }
        }

        Button {
          id: settingsNavButton
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          text: content.compact ? "" : "Settings"
          iconText: "󰒓"
          tooltipText: "Server, token and playback backend"
          foreground: root.foreground
          leftAlign: !content.compact
          focusable: false
          selected: root.mode === "setup" || root.currentPage === "settings"
          hasCursor: root.cursorOn("sidebar", "settings")
          onClicked: root.activateSidebar("settings")
          onHovered: function(on) { if (on) root.setPanelCursor("sidebar", "settings") }
        }
      }

      Item {
        id: pane
        anchors.left: sidebar.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Row {
          id: pageHeader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.space(52)
          spacing: Style.space(5)

          Button {
            id: backButton
            visible: root.navStack.length > 0
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰁍"
            tooltipText: "Back · Alt+Left"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("header", "back")
            onClicked: root.goBack()
            onHovered: function(on) { if (on) root.setPanelCursor("header", "back") }
          }

          Column {
            width: Math.max(Style.space(80), parent.width
              - (backButton.visible ? backButton.width + parent.spacing : 0)
              - refreshButton.width - pipButton.width - closeButton.width
              - parent.spacing * 3)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              text: root.pageTitle()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: root.pageSubtitle()
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          Button {
            id: refreshButton
            anchors.verticalCenter: parent.verticalCenter
            visible: root.configured() && root.mode !== "setup"
            iconText: "󰑐"
            tooltipText: "Refresh · R"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("header", "refresh")
            onClicked: root.refresh()
            onHovered: function(on) { if (on) root.setPanelCursor("header", "refresh") }
          }

          Button {
            id: pipButton
            anchors.verticalCenter: parent.verticalCenter
            // Until the now-playing bar exists (wave 3) this is the only way
            // back out of the floaty surface, so it stays in the header.
            iconText: root.windowed ? "\u{f0403}" : "\u{f0b26}"
            tooltipText: root.windowed ? "Send to corner panel" : "Back to a real window"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("header", "pip")
            onClicked: root.toggleSurface()
            onHovered: function(on) { if (on) root.setPanelCursor("header", "pip") }
          }

          Button {
            id: closeButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            // The armed state has to be visible or the second Esc is a guess.
            foreground: root.escapeCloseArmed ? root.urgent : root.foreground
            bordered: root.escapeCloseArmed
            tooltipText: root.escapeCloseArmed ? "Press Esc again to close" : "Close · Esc, Esc"
            focusable: false
            hasCursor: root.cursorOn("header", "close")
            onClicked: root.close()
            onHovered: function(on) { if (on) root.setPanelCursor("header", "close") }
          }
        }

        BorderSurface {
          id: statusBanner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: pageHeader.bottom
          anchors.topMargin: visible ? Style.space(6) : 0
          visible: root.statusText !== ""
          // Both the height and the margin collapse so an empty banner costs
          // exactly zero and nothing below it shifts.
          implicitHeight: visible ? bannerText.implicitHeight + Style.space(12) : 0
          height: implicitHeight
          radius: Style.cornerRadius
          color: root.statusUrgent
            ? Style.selectedFillFor(root.foreground, root.urgent)
            : Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground,
            root.statusUrgent ? root.urgent : root.accent)

          Text {
            id: bannerText
            anchors.fill: parent
            anchors.margins: Style.space(6)
            text: root.statusText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }
        }

        TextField {
          id: searchInput
          // QQC2 TextField consumes Tab for its own focus chain, so region
          // cycling dies inside the field unless Tab is forwarded by hand
          // (field-tested: Tab did nothing, then "j" typed into the query).
          Keys.onTabPressed: function(event) { event.accepted = true; root.cycleRegion(1) }
          Keys.onBacktabPressed: function(event) { event.accepted = true; root.cycleRegion(-1) }
          // Focus and cursor region must never disagree: open() focuses this
          // field directly, and if the region still says "page", the first Tab
          // walks page->sidebar and the second wraps right back into the field
          // (field-tested: Tab Tab j searched for "j" instead of navigating).
          onActiveFocusChanged: if (activeFocus) root.setPanelCursor("search", "input")
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: statusBanner.visible ? statusBanner.bottom : pageHeader.bottom
          anchors.topMargin: visible ? Style.space(8) : 0
          height: visible ? Style.space(38) : 0
          visible: root.configured() && root.mode !== "setup"
          foreground: root.foreground
          accent: root.accent
          placeholderText: "Search movies and TV · /"
          hasCursor: root.cursorOn("search", "input")
          onTextEdited: {
            searchDebounce.restart()
            root.setPanelCursor("search", "input")
          }
          onAccepted: root.searchAccepted()
          onHoveredChanged: if (hovered) root.setPanelCursor("search", "input")
        }

        Loader {
          id: pageLoader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: searchInput.visible
            ? searchInput.bottom
            : (statusBanner.visible ? statusBanner.bottom : pageHeader.bottom)
          anchors.topMargin: Style.space(8)
          anchors.bottom: parent.bottom
          // Re-evaluates because pageComponent() reads mode/currentPage.
          sourceComponent: root.pageComponent()
        }
      }
    }

    // ================= playing (wave-1 parity; theater is wave 3) =================
    Item {
      id: playingView
      anchors.fill: parent
      anchors.margins: Style.space(14)
      visible: root.mode === "playing"

      BorderSurface {
        id: videoWell
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: transportRow.top
        anchors.bottomMargin: Style.space(10)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, root.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

        VideoOutput {
          id: videoOut
          anchors.fill: parent
          anchors.margins: Style.space(2)
          visible: root.backend !== "mpv"
          fillMode: VideoOutput.PreserveAspectFit
        }

        // mpv draws into its own window, so in that mode this well is a plate.
        Text {
          anchors.centerIn: parent
          visible: root.backend === "mpv"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
          text: root.triedTranscode ? "Playing via server transcode" : "Playing in mpv (hardware decode)"
        }
      }

      Item {
        id: transportRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(72)

        BorderSurface {
          id: seekTrack
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.space(7)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          Rectangle {
            height: parent.height
            radius: parent.radius
            color: root.accent
            width: root.dispDuration > 0
              ? Math.max(0, Math.min(parent.width, parent.width * (root.dispTime / root.dispDuration)))
              : 0
            // Sliders are the one place the design allows easing; the poll
            // tick only lands once a second and a hard jump reads as a stall.
            Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          }

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) { if (width > 0) root.seekAbs(mouse.x / width) }
          }
        }

        Column {
          anchors.left: parent.left
          anchors.top: seekTrack.bottom
          anchors.topMargin: Style.space(8)
          spacing: Style.space(1)

          Text {
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            text: Model.fmtDuration(root.dispTime) + " / " + Model.fmtDuration(root.dispDuration)
          }
          Text {
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.currentTitle
          }
        }

        Row {
          anchors.right: parent.right
          anchors.top: seekTrack.bottom
          anchors.topMargin: Style.space(4)
          spacing: Style.space(6)

          TransportButton {
            glyphText: "󰒮"
            tooltipText: "Back 10s · ←"
            foreground: root.foreground
            hasCursor: root.cursorOn("playing", "rewind")
            onClicked: root.seekRel(-10)
            onHovered: function(on) { if (on) root.setPanelCursor("playing", "rewind") }
          }

          TransportButton {
            glyphText: root.isPaused ? "󰐊" : "󰏤"
            glyphSize: Style.font.iconLarge
            tooltipText: root.isPaused ? "Play · Space" : "Pause · Space"
            foreground: root.foreground
            hasCursor: root.cursorOn("playing", "play")
            onClicked: root.togglePause()
            onHovered: function(on) { if (on) root.setPanelCursor("playing", "play") }
          }

          TransportButton {
            glyphText: "󰒭"
            tooltipText: "Forward 10s · →"
            foreground: root.foreground
            hasCursor: root.cursorOn("playing", "forward")
            onClicked: root.seekRel(10)
            onHovered: function(on) { if (on) root.setPanelCursor("playing", "forward") }
          }

          TransportButton {
            visible: !root.mpvMode
            glyphText: audio.muted ? "󰖁" : "󰕾"
            tooltipText: audio.muted ? "Unmute · M" : "Mute · M"
            foreground: audio.muted ? root.urgent : root.foreground
            hasCursor: root.cursorOn("playing", "mute")
            onClicked: audio.muted = !audio.muted
            onHovered: function(on) { if (on) root.setPanelCursor("playing", "mute") }
          }

          TransportButton {
            glyphText: "󰓛"
            tooltipText: "Stop"
            foreground: root.urgent
            hasCursor: root.cursorOn("playing", "stop")
            onClicked: root.stop()
            onHovered: function(on) { if (on) root.setPanelCursor("playing", "stop") }
          }
        }
      }
    }
  }
}
