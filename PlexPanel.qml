import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
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
  // Shared now-playing state: the shell injects the plugin's single
  // PlayerState.qml service instance because this property exists (see
  // shell.qml's panel Instantiator), and the bar widget reads the same
  // instance via bar.shell.serviceFor() for its marquee.
  property var service: null

  function syncPlayerState() {
    if (!root.service) return
    root.service.playing = root.mode === "playing"
    root.service.paused = root.isPaused
    root.service.title = root.currentTitle
  }
  onServiceChanged: root.syncPlayerState()
  onCurrentTitleChanged: root.syncPlayerState()
  // mode/isPaused sync rides the theater handlers below — a second handler
  // for the same signal is a QML creation-time error, not an override.

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

  // PanelSlider styles itself from a bar-like object and falls back to literal
  // hex when it has none. Hand it the panel's own theme roles so no slider in
  // this plugin ever paints an off-theme track or knob outline.
  readonly property var panelBar: QtObject {
    readonly property color foreground: root.foreground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
  }

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
  // Raw Plex art path for the playing item, stashed off the resolve response
  // so the minibar has a thumbnail without a second round trip.
  property string currentThumbPath: ""

  // Playback and view are orthogonal. `mode` stays the ENGINE's state — it is
  // "playing" for as long as a session exists, and the timeline ticks, the
  // scrobble threshold and close()'s pause semantics all key on it. `theater`
  // is only about who owns the window: true = video full-bleed, false = browse
  // with the now-playing minibar along the bottom and the session still live.
  // That split is what lets Esc leave the video without ending playback.
  property bool theater: false
  readonly property bool inTheater: root.mode === "playing" && root.theater
  readonly property bool minibarVisible: root.mode === "playing" && !root.theater

  // Ending a session can never leave the view stranded on a dead video surface
  // — nor stranded in the PiP, which has no browse UI to fall back to.
  onModeChanged: {
    if (root.mode !== "playing") {
      root.theater = false
      if (!root.windowed) root.exitPip()
    }
    root.syncPlayerState()
  }

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
  // app. The layer-shell panel remains as the secondary "floaty" mode, now a
  // pure picture-in-picture: video plus a whisper of controls, nothing else.
  property bool windowed: true

  // The PiP's resting inset, and the band around each screen edge inside which
  // a release parks on it. Free placement everywhere else; deterministic
  // corners where you actually want them.
  readonly property int pipInset: Style.space(14)
  readonly property int pipSnap: Style.space(40)

  // A PiP is only ever a picture. With no session it is a dead grey rectangle
  // with no browse UI and no obvious way back, and under the mpv backend the
  // picture lives in mpv's own window, so there is nothing to put in it.
  readonly property bool pipAvailable: root.mode === "playing" && !root.mpvMode

  function enterPip() {
    if (!root.pipAvailable || !root.windowed) return
    // The PiP *is* the theater on the floaty surface, so popping back later
    // lands on the picture rather than the minibar.
    root.theater = true
    // Bind the surface to the output the REAL WINDOW is on before it maps.
    // Setting `screen` while the window is unmapped is free — there is no
    // surface to tear down yet, Quickshell just records it — and it is half
    // the multi-monitor fix on its own: a layer surface that was never told
    // which output to use goes wherever the compositor puts it, which is
    // rarely the screen you were just watching on. FloatingWindow.screen is a
    // live readback of where the compositor actually has the toplevel, not a
    // hint we set once, so it stays right after the user drags the window.
    var host = appWindow.screen
    if (host && !root.sameScreen(host, root.pipScreen)) {
      window.screen = host
      root.clampMargins()
    }
    root.windowed = false
    root.savePosition()
    root.pokeTheaterControls()
    root.focusPrimary()
  }

  function exitPip() {
    if (root.windowed) return
    root.windowed = true
    root.savePosition()
    root.enterTheater() // no-op unless a session is still live
    root.focusPrimary()
  }

  function toggleSurface() {
    if (root.windowed) root.enterPip()
    else root.exitPip()
  }

  // ---- moving and resizing the real window ----
  //
  // The window draws no chrome, so there is no title bar to grab; dragging any
  // bare part of it moves it instead. Both of these hand the gesture to the
  // compositor on the first call and then stop being involved — no delta
  // tracking, no coordinate frame to fight (the PiP comment further down is the
  // long version of why that matters), and it works on a TILED window as well
  // as a floating one because the compositor decides what the gesture means.
  //
  // The threshold is the whole reason a plain click still does nothing: without
  // it, every click that misses a control would start a move.
  readonly property int dragThreshold: Style.space(6)

  function beginWindowDrag() {
    if (!root.windowed) return false
    return appWindow.startSystemMove()
  }

  // ---- which output the PiP lives on ----
  //
  // A layer surface is bound to ONE wl_output for its entire life. There is no
  // "move me to that monitor" request in wlr-layer-shell, and the PiP is a
  // full-screen surface masked to a card, so the card is trapped on whatever
  // output the surface spawned on — the field complaint this block exists to
  // answer, from a desk with a 4K panel next to two 1440p ones.
  //
  // Reassigning `PanelWindow.screen` DOES work at runtime. Quickshell
  // implements it as hide → setScreen → show, and because WlrLayershell forces
  // `deleteOnInvisible`, that hide DESTROYS the zwlr_layer_surface_v1 and the
  // show creates a fresh one bound to the new output. One flicker, which is
  // fine — but the keyboard focus and any pointer grab go down with the old
  // surface, and that is what decides the drag design below.
  //
  // The shell's own multi-monitor idiom (Variants over Quickshell.screens, one
  // PanelWindow per output) is not open to us: the PiP hosts `videoLayer`, and
  // player.videoOutput is a single sink pointer QtMultimedia holds for the life
  // of the session. One surface per screen would mean one video sink per
  // screen, which is precisely what the videoLayer comment at the bottom of
  // this file forbids. So: one surface, reassigned.

  // ShellScreen.x/y/width/height are in the compositor's GLOBAL logical
  // coordinate space — the same numbers `hyprctl monitors` prints — so a
  // neighbouring output's rectangle can be tested directly against a pointer
  // position built from this surface's scene coordinates.
  readonly property var pipScreen: window.screen

  // The clamp measures against the SCREEN rather than the surface. Right after
  // a handoff the old surface has been destroyed and its replacement has not
  // been configured yet, so `window.width` still describes the output we just
  // left; the ShellScreen is correct the instant `screen` is assigned. (The
  // resize grip already trusted `window.screen.width` for the same reason.)
  readonly property int pipAreaWidth: root.pipScreen && root.pipScreen.width > 0
    ? root.pipScreen.width : (window.width > 0 ? window.width : 0)
  readonly property int pipAreaHeight: root.pipScreen && root.pipScreen.height > 0
    ? root.pipScreen.height : (window.height > 0 ? window.height : 0)

  // Margins measure the PiP CARD's distance from its screen's edges, not the
  // surface's — the layer surface is full-screen and never moves.
  function clampMargins() {
    var w = root.pipAreaWidth
    var h = root.pipAreaHeight
    if (w > 0) root.marginRight = Math.max(0, Math.min(root.marginRight, w - root.videoWidth))
    if (h > 0) root.marginBottom = Math.max(0, Math.min(root.marginBottom, h - root.videoHeight))
  }

  // Edge magnetism on release. Landing within the snap band of an edge parks on
  // the standard inset, so releasing anywhere near a corner gives the same
  // resting place every time — and both axes snapping is a corner snap.
  function snapPip() {
    var w = root.pipAreaWidth
    var h = root.pipAreaHeight
    if (root.marginRight < root.pipSnap) root.marginRight = root.pipInset
    else if (w > 0 && root.marginRight > w - root.videoWidth - root.pipSnap)
      root.marginRight = Math.max(0, w - root.videoWidth - root.pipInset)
    if (root.marginBottom < root.pipSnap) root.marginBottom = root.pipInset
    else if (h > 0 && root.marginBottom > h - root.videoHeight - root.pipSnap)
      root.marginBottom = Math.max(0, h - root.videoHeight - root.pipInset)
    root.clampMargins()
    root.savePosition()
  }

  // ShellScreen wrappers are not guaranteed to be the same JS object across
  // reads, so identity is not a safe test; the connector name is.
  function sameScreen(a, b) {
    if (!a || !b) return false
    var an = String(a.name || "")
    var bn = String(b.name || "")
    if (an !== "" && bn !== "") return an === bn
    return a === b
  }

  function screenAtGlobal(gx, gy) {
    var list = Quickshell.screens
    if (!list) return null
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (!s) continue
      if (gx >= s.x && gx < s.x + s.width && gy >= s.y && gy < s.y + s.height) return s
    }
    return null
  }

  // Every handoff ends the same way: the new surface is a NEW surface, so the
  // keyboard focus the old one held is simply gone. Re-claim it once the swap
  // has actually happened rather than in the same tick, which is still inside
  // the old surface's teardown.
  function commitPipScreen(next) {
    window.screen = next
    root.snapPip()
    Qt.callLater(function() { if (!root.windowed) pipKeyHost.forceActiveFocus() })
  }

  // Drop handler for the card drag, taking the pointer in this surface's scene
  // coordinates plus where inside the card it grabbed. See the long comment on
  // pipDrag for why this runs on release rather than during the gesture.
  function handlePipDrop(sceneX, sceneY, grabX, grabY) {
    var cur = root.pipScreen
    var ox = cur ? cur.x : 0
    var oy = cur ? cur.y : 0
    var target = root.screenAtGlobal(ox + sceneX, oy + sceneY)
    if (!target || root.sameScreen(target, cur)) { root.snapPip(); return }
    // Land the card under the pointer on the new output, holding the same grab
    // offset the gesture started with — otherwise it jumps by however far the
    // clamp had pinned it against the edge on the way out.
    var localX = (ox + sceneX - grabX) - target.x
    var localY = (oy + sceneY - grabY) - target.y
    root.marginRight = Math.round(target.width - root.videoWidth - localX)
    root.marginBottom = Math.round(target.height - root.videoHeight - localY)
    root.commitPipScreen(target)
  }

  // Keyboard-first sibling of the drag handoff, and the only way to do this at
  // all when the PiP is parked on a monitor the pointer is not on. Position
  // carries across PROPORTIONALLY rather than literally: the same margins on a
  // 4K panel and a 1440p one are visibly different placements, but "it was
  // tucked into the bottom-right" survives the trip.
  function cyclePipScreen(dir) {
    var list = Quickshell.screens
    if (!list || list.length < 2) return
    var cur = root.pipScreen
    var at = -1
    for (var i = 0; i < list.length; i++) if (root.sameScreen(list[i], cur)) { at = i; break }
    if (at < 0) at = 0
    var next = list[((at + dir) % list.length + list.length) % list.length]
    if (!next || root.sameScreen(next, cur)) return
    var spanX = Math.max(1, root.pipAreaWidth - root.videoWidth)
    var spanY = Math.max(1, root.pipAreaHeight - root.videoHeight)
    var fracX = Math.max(0, Math.min(1, root.marginRight / spanX))
    var fracY = Math.max(0, Math.min(1, root.marginBottom / spanY))
    root.marginRight = Math.round(fracX * Math.max(0, next.width - root.videoWidth))
    root.marginBottom = Math.round(fracY * Math.max(0, next.height - root.videoHeight))
    root.commitPipScreen(next)
    root.pokeTheaterControls()
  }

  // Growing the card leftwards can push it off the screen edge it is measured
  // from; re-clamp whenever the resize grip changes the width.
  onVideoWidthChanged: root.clampMargins()

  function saveWidth() {
    posSave.width = "" + root.videoWidth
    posSave.running = true
  }

  // Volume moves in 5% key steps and in slider drags, so the write is deferred:
  // one shell process per keystroke (or per frame) is exactly the mistake the
  // resize grip already documents.
  Timer {
    id: volumeSaveDebounce
    interval: 600
    repeat: false
    onTriggered: posSave.running = true
  }

  function saveVolume() { volumeSaveDebounce.restart() }

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
    // Bound rather than staged like the three above: every writer of this file
    // (savePosition, saveWidth, saveVolume) must emit the CURRENT volume, and a
    // binding cannot go stale the way a field only one of them sets would.
    // Rebuilding the command string is free here — volume moves on release and
    // key steps, not on every drag frame.
    property string volume: "" + root.volumePct
    running: false
    command: ["sh", "-c",
      "d='" + root.stateDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
      + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
      + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& umask 077 && t=.window.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
      + "&& printf '{\"right\":%s,\"bottom\":%s,\"width\":%s,\"windowed\":%s,\"volume\":%s}' "
      + posSave.right + " " + posSave.bottom + " " + posSave.width + " " + posSave.windowed
      + " " + posSave.volume
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
          if (doc.width !== undefined) root.videoWidth = Math.max(280, Math.min(3800, doc.width | 0))
          if (doc.volume !== undefined) root.volumePct = Math.max(0, Math.min(200, doc.volume | 0))
          // Nothing is playing at load, and a PiP with no session shows no
          // picture and offers no way to start one — a persisted floaty always
          // comes back as the real window.
          if (doc.windowed !== undefined)
            root.windowed = doc.windowed === true || !root.pipAvailable
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
  // The two surfaces have their own key hosts: the browse tree lives only in
  // the real window now, so nothing inside it can hold the caret while the PiP
  // is up (its window is not even mapped).
  function focusKeyHost() {
    if (root.windowed) keyHost.forceActiveFocus()
    else pipKeyHost.forceActiveFocus()
  }

  function focusPrimary() {
    // Defer until the mode's UI is visible; typing should search immediately.
    // Theater has no search box and its keys are transport keys, so the caret
    // parks on keyHost there — but browsing with a live session behind the
    // minibar is still browsing, and should land in the search field.
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.windowed && !root.inTheater && searchInput.visible) searchInput.forceActiveFocus()
      else root.focusKeyHost()
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
    // Drop the old artwork now: a minibar showing the last thing you watched
    // beside the new title is worse than a placeholder glyph for one second.
    root.currentThumbPath = ""
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
      root.currentThumbPath = root.metadataThumb(jsonText)
      root.stashStreams(jsonText)
      var mediaUrl = root.server + partKey
      if (root.backend !== "mpv") mediaUrl += "?X-Plex-Token=" + root.token
      playSource(mediaUrl, resolve.title)
    } catch (e) {
      fail("Could not resolve media")
    }
  }

  // Model.parsePlaybackMetadata deliberately only knows about playback (it is
  // frozen and pinned), but the resolve body already carries the artwork the
  // minibar wants — read it out of the same response instead of asking twice.
  function metadataThumb(jsonText) {
    try {
      var doc = JSON.parse(jsonText)
      var mc = doc && doc.MediaContainer
      var meta = mc && mc.Metadata && mc.Metadata.length > 0 ? mc.Metadata[0] : null
      if (!meta) return ""
      var item = Api.itemFromMetadata(meta)
      return String(item.thumbPath || item.artPath || "")
    } catch (e) {
      return ""
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
    root.clearSeekPreview()
    if (root.backend === "mpv") startMpv(url)
    else startInternal(url)
    pollTimer.restart()
    // Starting playback always drops into theater (enterTheater parks focus on
    // keyHost too — the search field hides, so transport keys need a home).
    root.enterTheater()
  }

  // ---- theater / browse view switch ----
  // Neither of these touches the engine: mode, the poll timer and the timeline
  // reports are unaffected, which is the entire point of the split.
  function enterTheater() {
    if (root.mode !== "playing") return
    root.theater = true
    root.pokeTheaterControls()
    root.focusKeyHost()
    root.setPanelCursor("playing", "play")
  }

  function exitTheater() {
    if (!root.theater) return
    root.theater = false
    // Browsing means the real window: the PiP has no list to drop back to.
    if (!root.windowed) { root.windowed = true; root.savePosition() }
    root.focusKeyHost()
    // Hand the highlight to the bar that just appeared, so the first Enter
    // goes straight back to theater.
    root.setPanelCursor("minibar", "expand")
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
        // mpv does its own >100% gain, so the 0–200 scale goes straight in and
        // the PipeWire boost never runs under this backend.
        "--volume-max=200", "--volume=" + root.volumePct,
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

  // Mute belongs to the internal backend's AudioOutput, which is file-scope
  // here; the theater strip is a separate file, so it gets these instead.
  readonly property bool audioMuted: audio.muted

  function toggleMute() {
    if (root.mpvMode) return
    audio.muted = !audio.muted
  }

  // ---- volume, 0–200% ----
  //
  // QtMultimedia's AudioOutput.volume is hard-capped at 1.0 — there is no boost
  // in Qt at all — so 0–100 is the player's own gain and 100–200 has to come
  // from the graph, where PipeWire happily runs a stream above unity. Quiet
  // film mixes are the reason this exists.
  //
  // mpv needs none of that: it takes 0–200 natively (--volume-max=200 is in its
  // argv) and gets the number over the same IPC as every other command.
  property int volumePct: 60
  readonly property real audioVolume: Math.min(1, root.volumePct / 100)

  // Set by every volume change so the strip can flash the percentage without
  // the pointer being anywhere near the slider.
  property bool volumeAdjusting: false

  Timer {
    id: volumeAdjustTimer
    interval: 1500
    repeat: false
    onTriggered: root.volumeAdjusting = false
  }

  // mpvSend spawns a socat per call, and a slider drag emits an event per
  // frame; coalesce so a drag costs one process rather than sixty.
  Timer {
    id: mpvVolumePush
    interval: 120
    repeat: false
    onTriggered: if (root.mpvMode)
      root.mpvSend('{"command":["set_property","volume",' + root.volumePct + ']}')
  }

  function setVolumePct(pct) {
    var next = Math.max(0, Math.min(200, Math.round(Number(pct) || 0)))
    root.volumeAdjusting = true
    volumeAdjustTimer.restart()
    if (next === root.volumePct) return
    root.volumePct = next
    // mpv takes the 0–200 number as-is; the internal backend splits at 100.
    if (root.mpvMode) mpvVolumePush.restart()
    root.saveVolume()
  }

  function nudgeVolume(delta) { root.setVolumePct(root.volumePct + delta) }

  // ---- the 100–200 zone: PipeWire per-stream boost ----
  //
  // The quickshell PROCESS publishes several identical-looking output streams —
  // node.name, media.name and application.name are all just "quickshell" — so
  // there is no reliable way to pick out the one this player feeds. The
  // sanctioned trade: boost every quickshell output stream while the boost is
  // live, remember each one touched, and put them all back to unity the moment
  // it is not. A notification ping that is briefly loud is an accepted cost on a
  // single-user desktop; a graph left boosted after playback is not, which is
  // why the deactivation set below is deliberately wide (stop, finish, failure,
  // close, item end, session lock, backend switch, volume back under 100).
  // Pausing is NOT in it: a paused film keeps the level you chose for it.
  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []

  readonly property var quickshellStreams: {
    var out = []
    for (var i = 0; i < root.pwNodes.length; i++) {
      var n = root.pwNodes[i]
      if (!n || !n.isStream) continue
      if (String(n.name || "") !== "quickshell") continue
      // Same playback-stream test the shell's audio panel uses, and for the
      // same reason: node.properties is invalid until a node is bound, and
      // reading it during node churn can destabilize the Pipewire service.
      if (n.isSink !== true && String(n.type || "").indexOf("Output") < 0) continue
      out.push(n)
    }
    return out
  }

  // audio (and therefore audio.volume) is only valid on a BOUND node.
  PwObjectTracker { objects: root.quickshellStreams }

  property var boostedStreams: []

  readonly property bool volumeBoostActive: root.opened
    && !root.sessionLocked
    && root.mode === "playing"
    && root.backend !== "mpv"
    && root.volumePct > 100

  function applyStreamBoost() {
    if (!root.volumeBoostActive) { root.restoreStreamVolumes(); return }
    var live = root.quickshellStreams
    var target = root.volumePct / 100
    var touched = []
    for (var i = 0; i < live.length; i++) {
      var n = live[i]
      if (!n || !n.audio) continue
      if (Math.abs(n.audio.volume - target) > 0.001) n.audio.volume = target
      touched.push(n)
    }
    root.boostedStreams = touched
  }

  function restoreStreamVolumes() {
    if (root.boostedStreams.length === 0) return
    var live = root.quickshellStreams
    for (var i = 0; i < root.boostedStreams.length; i++) {
      var n = root.boostedStreams[i]
      // Only touch what PipeWire still publishes: a departed stream has nothing
      // to restore and its wrapper may already be on its way out.
      if (!n || live.indexOf(n) < 0 || !n.audio) continue
      // Never stomp a level the user lowered by hand in the audio panel — the
      // only thing being undone here is our own boost.
      if (n.audio.volume > 1) n.audio.volume = 1
    }
    root.boostedStreams = []
  }

  onVolumeBoostActiveChanged: root.applyStreamBoost()
  onVolumePctChanged: root.applyStreamBoost()
  onQuickshellStreamsChanged: root.applyStreamBoost()

  // The player creates a fresh stream per playback, and a node that has only
  // just appeared is not bound yet, so its volume cannot be written on the tick
  // it shows up. Re-assert while the boost is up; it settles in one pass and
  // then costs a comparison per node.
  Timer {
    id: boostAssert
    interval: 400
    repeat: true
    running: root.volumeBoostActive
    onTriggered: root.applyStreamBoost()
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

  // ---- asynchronous seek, previewed until acknowledged ----
  // Both backends answer a seek late: the internal player re-buffers, and mpv
  // only reports its new time-pos on the next 1 s poll. A slider bound straight
  // to dispTime therefore snaps back to where you dragged from, which reads as
  // "the seek didn't take". Hold the previewed position until the backend
  // reports it (or gives up). Simplified from the Spotify plugin's
  // PlaybackSlider (MIT) — same shape, no separate component.
  property real seekPreview: -1
  property double seekPreviewAt: 0
  property string seekPreviewKey: ""
  readonly property bool seekPending: root.seekPreview >= 0
  readonly property real seekDisplayTime: root.seekPending ? root.seekPreview : root.dispTime
  readonly property real seekAckTolerance: 2
  readonly property int seekAckMinMs: 300
  readonly property int seekAckTimeoutMs: 8000

  function previewSeek(seconds) {
    var span = Math.max(0, root.dispDuration)
    root.seekPreview = Math.max(0, Math.min(span, Number(seconds) || 0))
    root.seekPreviewKey = root.currentRatingKey
    root.seekPreviewAt = Date.now()
    seekAckTimer.restart()
  }

  function clearSeekPreview() {
    seekAckTimer.stop()
    root.seekPreview = -1
    root.seekPreviewAt = 0
    root.seekPreviewKey = ""
  }

  // Absolute seek from a slider drag.
  function commitSeek(seconds) {
    root.previewSeek(seconds)
    if (root.dispDuration > 0) root.seekAbs(root.seekPreview / root.dispDuration)
  }

  // Relative seek from a transport button or an arrow key. Previewed for the
  // same reason, and stacked on the pending preview so a double-tap of ← moves
  // twenty seconds on screen rather than fighting the stale reported position.
  function nudgeSeek(seconds) {
    if (root.dispDuration > 0)
      root.previewSeek((root.seekPending ? root.seekPreview : root.dispTime) + seconds)
    root.seekRel(seconds)
  }

  Timer {
    id: seekAckTimer
    interval: 50
    repeat: true
    onTriggered: {
      if (!root.seekPending) { stop(); return }
      // A different item is playing: the previewed position describes media
      // that is no longer on screen.
      if (root.seekPreviewKey !== root.currentRatingKey) { root.clearSeekPreview(); return }
      var elapsed = Date.now() - root.seekPreviewAt
      if (elapsed >= root.seekAckTimeoutMs) { root.clearSeekPreview(); return }
      if (elapsed >= root.seekAckMinMs
          && Math.abs(root.dispTime - root.seekPreview) <= root.seekAckTolerance)
        root.clearSeekPreview()
    }
  }

  // ---- theater overlay auto-hide ----
  // A paused theater always shows its controls; while playing, any pointer
  // movement or key press buys another two seconds.
  property bool theaterControlsShown: true
  // An open track picker pins the strip: the list hangs off it, so fading the
  // strip out from under a list the user is reading would be absurd.
  readonly property bool theaterControlsVisible: root.theaterControlsShown
    || root.isPaused || root.trackPopup !== ""

  Timer {
    id: theaterHideTimer
    interval: 2000
    repeat: false
    onTriggered: root.theaterControlsShown = false
  }

  function pokeTheaterControls() {
    root.theaterControlsShown = true
    if (root.inTheater && !root.isPaused && root.trackPopup === "") theaterHideTimer.restart()
    else theaterHideTimer.stop()
  }

  onInTheaterChanged: root.pokeTheaterControls()
  onIsPausedChanged: {
    if (root.inTheater) root.pokeTheaterControls()
    root.syncPlayerState()
  }

  // ---- audio and subtitle tracks ----
  //
  // Half this library is dubbed, so "which audio" is a real question and
  // subtitles are only reachable by stream id. The Stream list comes off the
  // resolve response the panel already fetches; what differs is how a CHOICE
  // is delivered, and there are three answers depending on what is playing.
  //
  //  - The PUT runs in every case. It records the selection against the part
  //    server-side, so a transcode started later — by this pick or by a codec
  //    failure an hour from now — is muxed from the right tracks. Verified
  //    live: 200 with an empty body, no client-identifier header needed, the
  //    audio and subtitle params independent of one another, and
  //    subtitleStreamID=0 meaning "none".
  //  - Direct play on the internal backend then also moves the PLAYER's own
  //    active track, which is what makes the change audible immediately.
  //  - mpv gets an IPC property write, by ordinal.
  //
  // Anything the live pipeline cannot do itself falls back to asking the
  // server for a new stream — see rowNeedsServer.
  property var audioStreams: []
  property var subtitleStreams: []
  property string currentPartId: ""
  // Plex stream ids, as strings. "" on the subtitle side means "none".
  property string selectedAudioId: ""
  property string selectedSubtitleId: ""

  readonly property bool audioPickerAvailable: root.mode === "playing" && root.audioStreams.length > 1
  readonly property bool subtitlePickerAvailable: root.mode === "playing" && root.subtitleStreams.length > 0

  // Same reasoning as metadataThumb: Model.parsePlaybackMetadata is frozen and
  // knows only about playback, but the resolve body already carries the whole
  // Stream list, so the tracks are read out of the response we already have
  // rather than costing a second round trip.
  function stashStreams(jsonText) {
    var parsed = null
    try { parsed = Api.mapStreams(JSON.parse(jsonText)) } catch (e) { parsed = null }
    root.currentPartId = parsed ? String(parsed.partId || "") : ""
    root.audioStreams = parsed ? (parsed.audio || []) : []
    root.subtitleStreams = parsed ? (parsed.subtitle || []) : []
    root.selectedAudioId = Api.selectedStreamId(root.audioStreams)
    root.selectedSubtitleId = Api.selectedStreamId(root.subtitleStreams)
    root.closeTrackPopup()
  }

  // Qt refuses an active-track write before the media is open ("Cannot set
  // active track without open source") and does not populate the track lists
  // until the demuxer has resolved the streams. Waiting for a loaded buffer
  // covers both.
  readonly property bool playerTracksReady: root.backend !== "mpv"
    && (player.mediaStatus === MediaPlayer.LoadedMedia
      || player.mediaStatus === MediaPlayer.BufferedMedia
      || player.mediaStatus === MediaPlayer.BufferingMedia)

  // The player's list and Plex's describe the same file, so they should agree.
  // When they do not, the ordinals are meaningless and every pick has to go
  // back to the server — the usual cause being a transcode, which muxes
  // exactly one audio track however many the original had.
  function playerTracksAligned(kind) {
    if (root.mpvMode || !root.playerTracksReady) return false
    var streams = kind === "audio" ? root.audioStreams : root.subtitleStreams
    var embedded = 0
    for (var i = 0; i < streams.length; i++) if (streams[i] && !streams[i].external) embedded++
    var list = kind === "audio" ? player.audioTracks : player.subtitleTracks
    return embedded > 0 && list && list.length === embedded
  }

  // What the pipeline itself calls the track. Often nothing at all — ffmpeg
  // does not always surface a title or a language — in which case the caller
  // falls back to Plex's much richer label for the stream at that position.
  function playerTrackLabel(kind, ordinal) {
    if (!root.playerTracksAligned(kind) || ordinal < 0) return ""
    var list = kind === "audio" ? player.audioTracks : player.subtitleTracks
    if (!list || ordinal >= list.length) return ""
    var md = list[ordinal]
    if (!md) return ""
    var title = ""
    var lang = ""
    try {
      title = String(md.stringValue(MediaMetaData.Title) || "")
      lang = String(md.stringValue(MediaMetaData.Language) || "")
    } catch (e) { return "" }
    if (lang !== "" && title !== "") return lang + " · " + title
    return lang !== "" ? lang : title
  }

  // Rows are computed live from current state on every read, so a picker left
  // open across an item change can never activate a stale stream id.
  function trackRows(kind) {
    if (kind !== "audio" && kind !== "subtitle") return []
    var isAudio = kind === "audio"
    var streams = isAudio ? root.audioStreams : root.subtitleStreams
    var chosen = isAudio ? root.selectedAudioId : root.selectedSubtitleId
    var rows = []
    if (!isAudio) {
      rows.push({ label: "None", streamId: "", ordinal: -1, current: chosen === "",
        external: false, image: false, none: true })
    }
    for (var i = 0; i < streams.length; i++) {
      var s = streams[i]
      if (!s) continue
      var id = String(s.id || "")
      var fromPlayer = s.external ? "" : root.playerTrackLabel(kind, s.ordinal)
      rows.push({
        label: fromPlayer !== "" ? fromPlayer : String(s.label || ("Track " + (i + 1))),
        streamId: id,
        ordinal: Number(s.ordinal),
        current: chosen !== "" && chosen === id,
        external: s.external === true,
        image: s.image === true,
        none: false
      })
    }
    return rows
  }

  // Can the live pipeline make this change itself, or does the server have to
  // build a new stream for it?
  function rowNeedsServer(kind, row) {
    if (!row) return false
    if (row.none === true) return false
    // A sidecar file is in no container, so neither player can see it.
    if (row.external === true) return true
    // mpv draws anything that is muxed, image subtitles included.
    if (root.mpvMode) return false
    // Qt's ffmpeg backend only ever reads a subtitle rect's TEXT payload; the
    // bitmap one is never touched, so a PGS or VOBSUB track cannot be drawn
    // in-window at all and the server has to burn it into the picture. Not a
    // corner case here — Akira ships three image tracks and one SRT.
    if (kind === "subtitle" && row.image === true) return true
    return !root.playerTracksAligned(kind)
  }

  function setPlayerAudioTrack(ordinal) {
    if (!root.playerTracksReady) return false
    if (ordinal < 0 || ordinal >= player.audioTracks.length) return false
    player.activeAudioTrack = ordinal
    return true
  }

  function setPlayerSubtitleTrack(ordinal) {
    if (!root.playerTracksReady) return false
    // -1 is Qt's "no subtitles", and its default.
    if (ordinal < 0) { player.activeSubtitleTrack = -1; return true }
    if (ordinal >= player.subtitleTracks.length) return false
    player.activeSubtitleTrack = ordinal
    return true
  }

  function activateTrackRow(kind, row) {
    if (!row) return
    var needsServer = root.rowNeedsServer(kind, row)
    root.closeTrackPopup()
    if (kind === "audio") root.selectedAudioId = String(row.streamId || "")
    else root.selectedSubtitleId = String(row.streamId || "")

    if (root.mpvMode) {
      // mpv numbers tracks from 1 per type, in container order — the same
      // order Plex lists its streams in, which is what `ordinal` counts.
      // Best-effort by construction: there is no cheap readback to confirm the
      // mux order matched, so a file whose container order disagreed with
      // Plex's would pick the neighbouring track.
      if (needsServer) { root.putTrackSelection(true); return }
      if (kind === "audio") root.mpvSend('{"command":["set_property","aid",' + (Number(row.ordinal) + 1) + ']}')
      else if (row.none === true) root.mpvSend('{"command":["set_property","sid","no"]}')
      else root.mpvSend('{"command":["set_property","sid",' + (Number(row.ordinal) + 1) + ']}')
      root.putTrackSelection(false)
      return
    }

    // A track change while a transcode is already running is a server change
    // by definition: that stream has one audio track in it.
    if (needsServer || root.triedTranscode) { root.putTrackSelection(true); return }
    var ok = kind === "audio"
      ? root.setPlayerAudioTrack(Number(row.ordinal))
      : root.setPlayerSubtitleTrack(Number(row.ordinal))
    root.putTrackSelection(!ok)
  }

  // The selection has to REACH the server before a transcode is asked for, or
  // the new stream is built from the old tracks. So the restart hangs off the
  // PUT's exit rather than racing it.
  property bool restartAfterPut: false
  // Queue of exactly one. Quickshell latches a Process's argv at start and
  // silently ignores writes to a running one, so a second pick landing while
  // the first PUT is still in flight would vanish — and the symptom would be
  // "the subtitle didn't change", with the server quietly holding the older
  // choice. Only the newest selection is worth sending, so a single slot is
  // enough; the payload is rebuilt from current state when it runs.
  property bool trackPutQueued: false
  property bool trackPutQueuedRestart: false

  function putTrackSelection(thenRestart) {
    if (trackPut.running) {
      root.trackPutQueued = true
      // A queued restart must survive being coalesced with a pick that did not
      // need one — dropping it would leave the server correct and the picture
      // still playing the old tracks.
      root.trackPutQueuedRestart = root.trackPutQueuedRestart || thenRestart === true
      return
    }
    root.restartAfterPut = thenRestart === true
    if (root.currentPartId === "" || !root.configured()) {
      if (root.restartAfterPut) { root.restartAfterPut = false; root.beginTrackRestart() }
      return
    }
    if (root.restartAfterPut) root.setStatus("Switching track — restarting the stream…", false)
    var subId = root.selectedSubtitleId === "" ? "0" : root.selectedSubtitleId
    trackPut.command = ["curl", "-s", "--fail", "--max-time", "5", "-o", "/dev/null", "-X", "PUT"]
      .concat(root.plexHeaders)
      .concat([Api.partSelectionUrl(root.server, root.currentPartId, root.selectedAudioId, subId)])
    trackPut.running = true
  }

  Process {
    id: trackPut
    running: false
    onExited: {
      var restart = root.restartAfterPut
      root.restartAfterPut = false
      if (root.trackPutQueued) {
        root.trackPutQueued = false
        var queued = root.trackPutQueuedRestart || restart
        root.trackPutQueuedRestart = false
        // Deferred so `running` has certainly settled back to false before the
        // next launch reads it — otherwise the queue could re-queue forever.
        Qt.callLater(function() { root.putTrackSelection(queued) })
        return
      }
      if (restart) root.beginTrackRestart()
    }
  }

  // Rejoin the film where we left it, on a stream the server has just re-muxed
  // to the chosen tracks. Deliberately the same machinery as the direct-play →
  // transcode fallback: resumeSec is what onMediaStatusChanged seeks to once
  // the new source reports LoadedMedia.
  function beginTrackRestart() {
    if (root.currentRatingKey === "" || root.mode !== "playing") return
    root.resumeSec = Math.max(0, Math.round(root.seekDisplayTime))
    root.triedTranscode = true
    root.playGen++
    root.clearSeekPreview()
    var url = root.transcodeUrl()
    if (root.backend === "mpv") root.startMpv(url)
    else root.startInternal(url)
  }

  // ---- the picker itself ----
  //
  // A plain list drawn on the theater overlay rather than a QQC2 Popup. It
  // needs no focus scope and no Shortcut objects of its own: the existing
  // dispatcher simply gives it first refusal while it is open, which is what
  // keeps it out of the layered-Esc chain's way instead of competing with it.
  property string trackPopup: "" // "" | "audio" | "subtitle"
  property int trackPopupIndex: 0

  function openTrackPopup(kind) {
    var rows = root.trackRows(kind)
    if (rows.length === 0) return
    root.trackPopup = kind
    var at = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].current) { at = i; break }
    root.trackPopupIndex = at
    root.pokeTheaterControls()
  }

  function closeTrackPopup() {
    if (root.trackPopup === "") return
    root.trackPopup = ""
    root.trackPopupIndex = 0
    // The strip was pinned open while the list was up; hand it back its timer.
    root.pokeTheaterControls()
  }

  function toggleTrackPopup(kind) {
    if (root.trackPopup === kind) root.closeTrackPopup()
    else root.openTrackPopup(kind)
  }

  function moveTrackPopup(delta) {
    var rows = root.trackRows(root.trackPopup)
    if (rows.length === 0) return
    var at = root.trackPopupIndex + delta
    root.trackPopupIndex = ((at % rows.length) + rows.length) % rows.length
    root.pokeTheaterControls()
  }

  function activateTrackPopup() {
    var kind = root.trackPopup
    var rows = root.trackRows(kind)
    if (root.trackPopupIndex < 0 || root.trackPopupIndex >= rows.length) {
      root.closeTrackPopup()
      return
    }
    root.activateTrackRow(kind, rows[root.trackPopupIndex])
  }

  // First refusal on the keyboard while a picker is open. Returning true is
  // what keeps Esc from walking the normal layered chain (popup first, THEN
  // theater, then the back-stack) and stops j/k reaching the transport.
  function handleTrackPopupKey(event, ctrl, alt) {
    if (root.trackPopup === "") return false
    var key = event.key
    var text = String(event.text || "").toLowerCase()
    if (key === Qt.Key_Escape) { root.closeTrackPopup(); return true }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) { root.activateTrackPopup(); return true }
    if (ctrl || alt) return false
    if (key === Qt.Key_Up || text === "k") { root.moveTrackPopup(-1); return true }
    if (key === Qt.Key_Down || text === "j") { root.moveTrackPopup(1); return true }
    if (key === Qt.Key_Home) { root.trackPopupIndex = 0; return true }
    if (key === Qt.Key_End) {
      root.trackPopupIndex = Math.max(0, root.trackRows(root.trackPopup).length - 1)
      return true
    }
    // Swapping straight between the two lists is worth a key of its own;
    // everything else is swallowed so a stray Space cannot pause the film
    // behind an open list.
    if (text === "a" && root.audioPickerAvailable) { root.toggleTrackPopup("audio"); return true }
    if (text === "s" && root.subtitlePickerAvailable) { root.toggleTrackPopup("subtitle"); return true }
    return true
  }

  function finishPlayback() {
    sendTimeline("stopped")
    pollTimer.stop()
    root.mode = "list"
    root.currentTitle = ""
    root.currentThumbPath = ""
    root.clearSeekPreview()
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
      // Hard-capped at 1.0 by Qt; everything above 100% is PipeWire's job.
      volume: root.audioVolume
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
  Component { id: theaterViewComponent; TheaterView { panel: root } }

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
    // Esc out of theater is a VIEW step, not a playback one — the session keeps
    // running and the minibar takes over. Only once you are already browsing
    // does Esc resume its normal layered walk (back-stack, then arm close).
    if (root.inTheater) {
      root.disarmEscapeClose()
      root.exitTheater()
      return
    }
    if (root.navStack.length > 0) {
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

  // Minibar cursor actions, left to right as they sit on the bar. "seek" is a
  // drag target rather than a command, but it stays in the walk so Tab-then-l
  // reaches the slider the same way the pointer does.
  readonly property var minibarActions: ["rewind", "play", "forward", "seek", "expand"]

  function activateMinibar(action) {
    var a = String(action || "")
    if (a === "rewind") { root.nudgeSeek(-10); return }
    if (a === "play") { root.togglePause(); return }
    if (a === "forward") { root.nudgeSeek(10); return }
    if (a === "expand") { root.enterTheater(); return }
  }

  function cycleRegion(dir) {
    var order = ["search", "page", "sidebar"]
    // The minibar joins the cycle only while it is actually on screen.
    if (root.minibarVisible) order.push("minibar")
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
    if (region === "minibar") {
      var bar = root.minibarActions
      root.setPanelCursor("minibar",
        bar.indexOf(root.cursorAction) >= 0 ? root.cursorAction : "play")
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
    if (root.cursorRegion === "minibar") {
      // The bar is one row at the bottom of the window: up leaves it, h/l walk
      // its actions.
      if (dy < 0) { root.enterRegion("page"); return }
      if (dx === 0) return
      var bar = root.minibarActions
      var spot = bar.indexOf(root.cursorAction)
      spot = spot < 0 ? 0 : ((spot + dx) % bar.length + bar.length) % bar.length
      root.setPanelCursor("minibar", bar[spot])
      return
    }
    // "page" — the page owns its own geometry, so it decides what a step means.
    var item = pageLoader.item
    if (item && typeof item.moveCursor === "function") item.moveCursor(dx, dy)
  }

  function activateCursor() {
    if (root.cursorRegion === "sidebar") { root.activateSidebar(root.cursorAction); return }
    if (root.cursorRegion === "minibar") { root.activateMinibar(root.cursorAction); return }
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
      root.nudgeSeek((key === Qt.Key_Left ? -1 : 1) * (shift ? 30 : 10))
      return true
    }
    if (!ctrl && !alt && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      root.nudgeVolume(key === Qt.Key_Up ? 5 : -5)
      return true
    }
    if (!ctrl && !alt && key === Qt.Key_M) {
      root.toggleMute()
      return true
    }
    // Both theater and the PiP route through here, so one line covers "put the
    // picture in the corner" and "give it back".
    if (!ctrl && !alt && key === Qt.Key_P) {
      root.toggleSurface()
      return true
    }
    // Theater only: the PiP strip is far too small for a list of eleven audio
    // tracks, so the pickers do not exist on that surface.
    if (root.windowed && !ctrl && !alt && key === Qt.Key_A && root.audioPickerAvailable) {
      root.toggleTrackPopup("audio")
      return true
    }
    if (root.windowed && !ctrl && !alt && key === Qt.Key_S && root.subtitlePickerAvailable) {
      root.toggleTrackPopup("subtitle")
      return true
    }
    return false
  }

  // The PiP's own dispatcher. It shares the transport keys with theater and
  // adds nothing else: there is no search, no page and no back-stack on that
  // surface, so Esc has exactly one meaning — put me back in the window.
  function handlePipKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    if (event.key === Qt.Key_Escape) { root.exitPip(); return true }
    root.pokeTheaterControls()
    // Moving the picture to another monitor is a PiP-only idea: in windowed
    // mode the compositor already owns that (Super+Shift+arrow), and `m` is
    // taken by mute. Shift walks the monitor list the other way.
    if (!ctrl && !alt && event.key === Qt.Key_N) {
      root.cyclePipScreen(shift ? -1 : 1)
      return true
    }
    return root.handlePlayingKey(event, ctrl, shift, alt)
  }

  function handleKey(event) {
    var key = event.key
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var text = String(event.text || "").toLowerCase()

    // An open picker gets first refusal — before Esc's layered walk and before
    // the transport keys, because it owns j/k and Enter while it is up.
    if (root.trackPopup !== "" && root.handleTrackPopupKey(event, ctrl, alt)) return true

    if (key === Qt.Key_Escape) { root.escapePressed(); return true }

    // Alt+Left is what every other app on this desktop uses for Back.
    if (alt && key === Qt.Key_Left) { root.goBack(); return true }

    // Theater owns the keyboard outright; browsing with a live session behind
    // the minibar keeps every normal browse key.
    if (root.inTheater) {
      root.pokeTheaterControls()
      return root.handlePlayingKey(event, ctrl, shift, alt)
    }

    // Global play/pause is the whole point of a minibar. A focused text field
    // never reaches this line — Qt only bubbles keys the field ignored, and a
    // TextField eats Space — so this cannot fire mid-query.
    if (root.mode === "playing" && !ctrl && !alt && key === Qt.Key_Space) {
      root.togglePause()
      return true
    }

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
    // A no-op unless a session is live: enterPip() guards on pipAvailable.
    if (!ctrl && !alt && text === "p") { root.toggleSurface(); return true }
    return false
  }

  // ---- floaty surface: the picture-in-picture ----
  //
  // The surface is FULL-SCREEN and never moves. That is the whole fix for the
  // drag oscillation.
  //
  // wlr-layer-shell has no move request — a layer surface's position is purely
  // anchor + margin, and `set_margin` is double-buffered: the compositor
  // applies it whenever it likes and never tells the client it landed. So a
  // handler that reads an item-local `mouse.x` and writes `margins` is reading
  // a coordinate frame that its own un-applied writes are still moving. The
  // pending delta gets counted again on the next event and the card orbits the
  // cursor. Quickshell offers no way out: `startSystemMove` exists only on
  // FloatingWindow (xdg-toplevel), PanelWindow has no position readback, and
  // nothing signals "margin applied".
  //
  // The shell's own answer, used by the bar's drag ghost
  // (/usr/share/omarchy/shell/plugins/bar/Bar.qml:1170-1190) and the
  // notification popups (plugins/notifications/Service.qml:974-978): anchor the
  // surface to all four edges, blank the input region with `mask` so the rest
  // of the screen stays click-through, and move an ordinary Item inside it.
  // Item coordinates are resolved entirely inside Qt's scene graph — the
  // position you set IS the position on the next frame, with no round trip to
  // oscillate against. marginRight/marginBottom keep their meaning (and their
  // persisted schema); they now place the CARD, not the surface.
  PanelWindow {
    id: window
    visible: root.opened && !root.windowed && !root.sessionLocked
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    onWidthChanged: root.clampMargins()
    onHeightChanged: root.clampMargins()
    WlrLayershell.namespace: "plexmini"
    WlrLayershell.layer: WlrLayer.Top
    // Only the card takes input; a full-screen surface that ate clicks would
    // make the desktop unusable behind it.
    mask: Region { item: pipCard }
    // OnDemand only. There is no browse or setup on this surface any more, so
    // nothing here ever needs to receive typing before the first click — and a
    // miniplayer that held an Exclusive grab would leave every other window on
    // the desktop deaf for as long as it sat in the corner. Clicking the card
    // arms the transport keys; clicking any window gives them back.
    WlrLayershell.keyboardFocus: root.opened
      ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: if (visible) root.focusPrimary()

    FocusScope {
      id: pipScope
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { if (root.handlePipKey(event)) event.accepted = true }

      // Focus parking spot for the floaty surface — `content`'s keyHost lives
      // in the other window, which is not even mapped while the PiP is up.
      Item { id: pipKeyHost; width: 0; height: 0; focus: true }

      BorderSurface {
        id: pipCard
        width: root.videoWidth
        height: root.videoHeight
        // Measured from the far edges so the card keeps its corner when the
        // screen resolution or the card's own width changes.
        x: Math.round(Math.max(0, pipScope.width - width - root.marginRight))
        y: Math.round(Math.max(0, pipScope.height - height - root.marginBottom))
        radius: Style.cornerRadius
        // Opaque: the letterbox bars around a 16:9 picture are the panel
        // background, exactly as they are in theater.
        color: root.background
        borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

        // Passive, so it keeps reporting while the pointer is parked on a
        // button in the strip — a MouseArea would hand hover to the topmost
        // item and the controls would fade out from under the cursor.
        HoverHandler { id: pipHover }

        // The video reparents in here (see videoLayer).
        Item { id: pipSlot; anchors.fill: parent }

        // Drag surface. Sits under the control strip so the buttons win their
        // own clicks, and reads SCENE coordinates: the scene belongs to the
        // full-screen surface, which never moves, so a press-time snapshot
        // plus an absolute delta tracks the pointer exactly 1:1.
        //
        // Crossing to another monitor is settled ON RELEASE, not mid-drag, and
        // that is a correctness requirement rather than a simplification.
        // Reassigning `window.screen` destroys this very surface (see the
        // screen block up top), and the surface is what holds Wayland's
        // implicit pointer grab — remapping mid-gesture would delete the grab
        // owner and the rest of the drag would be delivered to nothing, leaving
        // the card stranded wherever it happened to be. Waiting costs nothing,
        // because the grab keeps feeding us motion in THIS surface's scene
        // coordinates even once the pointer is over a different output: the
        // numbers simply run negative, or past `width`. The card visibly stops
        // at the edge until you let go, then lands where you dropped it.
        MouseArea {
          id: pipDrag
          anchors.fill: parent
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          property real pressX: 0
          property real pressY: 0
          property int pressRight: 0
          property int pressBottom: 0
          // Where inside the card the pointer took hold. Kept for the whole
          // gesture so a drop on another output can put the card back under
          // the pointer instead of at whatever edge the clamp pinned it to.
          property real grabX: 0
          property real grabY: 0
          property bool moved: false

          onPressed: function(mouse) {
            var p = mapToItem(null, mouse.x, mouse.y)
            pipDrag.pressX = p.x
            pipDrag.pressY = p.y
            pipDrag.pressRight = root.marginRight
            pipDrag.pressBottom = root.marginBottom
            pipDrag.grabX = p.x - pipCard.x
            pipDrag.grabY = p.y - pipCard.y
            pipDrag.moved = false
            // OnDemand focus only arrives on a click; claim it for the keys.
            pipKeyHost.forceActiveFocus()
            root.pokeTheaterControls()
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var p = mapToItem(null, mouse.x, mouse.y)
            root.marginRight = pipDrag.pressRight - (p.x - pipDrag.pressX)
            root.marginBottom = pipDrag.pressBottom - (p.y - pipDrag.pressY)
            root.clampMargins()
            pipDrag.moved = true
          }
          // A bare click on the picture is a focus grab, not a move: the
          // handoff (and its state write) belongs to gestures that actually
          // moved. handlePipDrop falls back to a plain snap when the drop
          // landed on the screen it started from.
          onReleased: function(mouse) {
            if (!pipDrag.moved) return
            var p = mapToItem(null, mouse.x, mouse.y)
            root.handlePipDrop(p.x, p.y, pipDrag.grabX, pipDrag.grabY)
          }
        }

        // resize grip — thin strip on the card's top-left corner, inside
        // bounds. Dragging left grows the miniwindow; width persists across
        // restarts. Above the drag surface so the corner resizes, not moves.
        MouseArea {
          id: resizeGrip
          anchors.left: parent.left
          anchors.top: parent.top
          width: Style.space(28)
          height: Style.space(28)
          z: 100
          cursorShape: Qt.SizeFDiagCursor
          property real sx: 0
          property int startW: 0
          onPressed: function(mouse) { sx = mapToItem(null, mouse.x, mouse.y).x; startW = root.videoWidth }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var gx = mapToItem(null, mouse.x, mouse.y).x
            // No save here: a write per mouse event spawned a shell process per
            // frame. The release below persists the settled width once.
            // Cap at the surface, not a constant: 900 was upstream's laptop-scale
            // limit and read as "not very big" on a 4K monitor (field report).
            root.videoWidth = Math.max(280, Math.min(
              (window.screen ? window.screen.width : 3800) - Style.space(28),
              startW + (sx - gx)))
          }
          onReleased: root.saveWidth()
        }

        // ---------- the whisper of controls ----------
        // Everything the PiP offers: scrub, play/pause, and the way back to the
        // real window. Fades like the theater strip and on the same timer, so
        // a key press wakes it even with the pointer parked elsewhere.
        BorderSurface {
          id: pipStrip
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          height: Style.space(40)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          opacity: pipHover.hovered || root.theaterControlsVisible ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 120 } }

          TransportButton {
            id: pipPlay
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            glyphText: root.isPaused ? "󰐊" : "󰏤"
            glyphSize: Style.font.iconLarge
            tooltipText: root.isPaused ? "Play · Space" : "Pause · Space"
            foreground: root.foreground
            hasCursor: root.cursorOn("pip", "play")
            onClicked: root.togglePause()
            onHovered: function(on) { if (on) root.setPanelCursor("pip", "play") }
          }

          Button {
            id: pipPop
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f0b26}"
            tooltipText: "Back to the window · Esc / P"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("pip", "window")
            onClicked: root.toggleSurface()
            onHovered: function(on) { if (on) root.setPanelCursor("pip", "window") }
          }

          // Only earns its place on a multi-head desk, and collapses to zero
          // width on a single one so the seek slider gets the pixels back.
          Button {
            id: pipScreenButton
            visible: Quickshell.screens.length > 1
            width: visible ? implicitWidth : 0
            anchors.right: pipPop.left
            anchors.rightMargin: visible ? Style.space(2) : 0
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f037a}"
            tooltipText: "Move to the next monitor · N"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("pip", "screen")
            onClicked: root.cyclePipScreen(1)
            onHovered: function(on) { if (on) root.setPanelCursor("pip", "screen") }
          }

          CursorSurface {
            id: pipSeekCursor
            anchors.left: pipPlay.right
            anchors.leftMargin: Style.space(6)
            anchors.right: pipScreenButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            height: pipSeekSlider.implicitHeight
            hasCursor: root.cursorOn("pip", "seek")
            foreground: root.foreground
            accent: root.accent
            // Same treatment as the other two scrubbers — see minibarSeek.
            fill: "transparent"
            borderSpec: Border.none()

            HoverHandler {
              onHoveredChanged: if (hovered) root.setPanelCursor("pip", "seek")
            }

            PanelSlider {
              id: pipSeekSlider
              anchors.fill: parent
              bar: root.panelBar
              knobColor: root.cursorOn("pip", "seek") ? root.accent : root.foreground
              minimum: 0
              maximum: Math.max(1, root.dispDuration)
              step: 10
              // The previewed position, not the reported one — see the
              // seek-ack block above for why the knob has to hold its ground.
              value: root.seekDisplayTime
              onMoved: function(seconds) { root.previewSeek(seconds) }
              onReleased: function(seconds) { root.commitSeek(seconds) }
            }
          }
        }
      }
    }
  }

  // Primary surface: a real xdg-toplevel window. Hyprland tiles, swaps,
  // fullscreens, and rules it like any application window. The whole browse
  // tree — sidebar, pages, search, setup, minibar — lives here and ONLY here,
  // so it never reparents; the one thing that still moves between surfaces is
  // the video (see videoLayer).
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

    FocusScope {
      id: content
      anchors.fill: parent
      focus: true

      // Below this the sidebar drops to an icon rail. Only the real window is
      // width-responsive now — the PiP has no sidebar to collapse — so this is
      // about a narrow TILED window, not about the floaty surface.
      readonly property bool compact: content.width < Style.space(760)

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }

      // Focus parking spot for when no text field should hold the caret.
      Item { id: keyHost; width: 0; height: 0 }

      // Drag-anywhere. Declared FIRST among the visual children so every row,
      // button and slider sits above it and keeps its own clicks — what reaches
      // here is bare background (the window margin, empty sidebar, gaps between
      // cards). Flickables above it still win their own drags, so a swipe over a
      // poster grid scrolls rather than moving the window.
      MouseArea {
        id: windowDrag
        anchors.fill: parent
        property real pressX: 0
        property real pressY: 0
        property bool handedOff: false

        onPressed: function(mouse) {
          windowDrag.pressX = mouse.x
          windowDrag.pressY = mouse.y
          windowDrag.handedOff = false
        }
        onPositionChanged: function(mouse) {
          if (!windowDrag.pressed || windowDrag.handedOff) return
          if (Math.abs(mouse.x - windowDrag.pressX) < root.dragThreshold
              && Math.abs(mouse.y - windowDrag.pressY) < root.dragThreshold) return
          windowDrag.handedOff = true
          root.beginWindowDrag()
        }
      }

      // The video parks here while the real window owns the picture.
      Item { id: theaterSlot; anchors.fill: parent }

      // ================= browse =================
      Item {
        id: browse
        anchors.fill: parent
        anchors.margins: Style.space(14)
        visible: !root.inTheater

        BorderSurface {
          id: sidebar
          anchors.left: parent.left
          anchors.top: parent.top
          // Everything above the minibar shrinks to make room for it, so a live
          // session never sits on top of the list it came from.
          anchors.bottom: minibarSeparator.visible ? minibarSeparator.top : parent.bottom
          anchors.bottomMargin: minibarSeparator.visible ? Style.space(10) : 0
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
          anchors.bottom: sidebar.bottom

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
              iconText: "\u{f0403}"
              // Deliberately still hoverable while unavailable: `enabled: false`
              // would kill the tooltip too, and the tooltip is the only place
              // that can say WHY the button is dead.
              foreground: root.pipAvailable ? root.foreground : root.muted
              tooltipText: root.pipAvailable
                ? "Picture-in-picture · P"
                : (root.mpvMode
                  ? "mpv has the picture in its own window"
                  : "Picture-in-picture · play something first")
              focusable: false
              hasCursor: root.cursorOn("header", "pip")
              // A no-op while unavailable — enterPip() guards on pipAvailable.
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

        // ---------- now-playing minibar ----------
        // Spans the full browse width under both sidebar and pane, Spotify-footer
        // style: artwork well, title + clock, transport, thin seek slider, and
        // the way back into theater. Only on screen while a session is live and
        // the video is not.
        PanelSeparator {
          id: minibarSeparator
          visible: root.minibarVisible
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: minibar.top
          anchors.bottomMargin: Style.space(10)
          foreground: root.foreground
        }

        BorderSurface {
          id: minibar
          visible: root.minibarVisible
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: visible ? Style.space(64) : 0
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          // Anything on the bar that is not itself a control takes you back to
          // theater. Declared first so the real controls sit above it and win
          // their own clicks. Hovering bare bar lights the expand button, which
          // both names what a click does and keeps one highlight on screen.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.enterTheater()
            onEntered: root.setPanelCursor("minibar", "expand")
          }

          BorderSurface {
            id: minibarArt
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: Math.max(Style.space(24), parent.height - Style.space(16))
            width: height
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              // Fit, not crop: episode stills are 16:9 and movie thumbs are 2:3,
              // and the well shows through either way.
              source: root.currentThumbPath === "" ? "" : root.imageUrl(root.currentThumbPath, 120, 120)
              sourceSize.width: 120
              sourceSize.height: 120
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: root.currentThumbPath === ""
              text: "󰎁"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            anchors.left: minibarArt.right
            anchors.leftMargin: Style.space(9)
            anchors.right: minibarSeek.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.currentTitle
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: Model.fmtDuration(root.seekDisplayTime) + " / " + Model.fmtDuration(root.dispDuration)
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          CursorSurface {
            id: minibarSeek
            // A narrow tiled window is narrower than the slider is useful at;
            // the bar keeps its transport and drops the scrubber there.
            visible: !content.compact
            width: visible ? Math.max(Style.space(90), minibar.width * 0.22) : 0
            height: minibarSlider.implicitHeight
            anchors.right: minibarTransport.left
            anchors.rightMargin: visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            hasCursor: root.cursorOn("minibar", "seek")
            foreground: root.foreground
            accent: root.accent
            // A scrubber gets no hover box. The panel-cursor plumbing stays
            // exactly as it was — hover still claims the cursor and the keyboard
            // "seek" action is still reachable — but the fill and the border are
            // dropped, because a rectangle snapping up around the timeline reads
            // as a rendering defect rather than a highlight. The knob below
            // carries the keyboard indication instead.
            fill: "transparent"
            borderSpec: Border.none()

            HoverHandler {
              onHoveredChanged: if (hovered) root.setPanelCursor("minibar", "seek")
            }

            PanelSlider {
              id: minibarSlider
              anchors.fill: parent
              bar: root.panelBar
              // PanelSlider's own hot state is mouse-only and read-only, so the
              // panel cursor speaks through the knob's color instead.
              knobColor: root.cursorOn("minibar", "seek") ? root.accent : root.foreground
              minimum: 0
              maximum: Math.max(1, root.dispDuration)
              step: 10
              value: root.seekDisplayTime
              onMoved: function(seconds) { root.previewSeek(seconds) }
              onReleased: function(seconds) { root.commitSeek(seconds) }

              HoverHandler { id: minibarSliderHover }
              PanelToolTip {
                visible: minibarSliderHover.hovered
                text: "Seek · ← / →"
              }
            }
          }

          Row {
            id: minibarTransport
            anchors.right: minibarExpand.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            TransportButton {
              glyphText: "󰒮"
              tooltipText: "Back 10s"
              foreground: root.foreground
              hasCursor: root.cursorOn("minibar", "rewind")
              onClicked: root.nudgeSeek(-10)
              onHovered: function(on) { if (on) root.setPanelCursor("minibar", "rewind") }
            }

            TransportButton {
              glyphText: root.isPaused ? "󰐊" : "󰏤"
              glyphSize: Style.font.iconLarge
              tooltipText: root.isPaused ? "Play · Space" : "Pause · Space"
              foreground: root.foreground
              hasCursor: root.cursorOn("minibar", "play")
              onClicked: root.togglePause()
              onHovered: function(on) { if (on) root.setPanelCursor("minibar", "play") }
            }

            TransportButton {
              glyphText: "󰒭"
              tooltipText: "Forward 10s"
              foreground: root.foreground
              hasCursor: root.cursorOn("minibar", "forward")
              onClicked: root.nudgeSeek(10)
              onHovered: function(on) { if (on) root.setPanelCursor("minibar", "forward") }
            }
          }

          Button {
            id: minibarExpand
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅃"
            tooltipText: "Theater · Enter"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("minibar", "expand")
            onClicked: root.enterTheater()
            onHovered: function(on) { if (on) root.setPanelCursor("minibar", "expand") }
          }
        }
      }

      // ================= theater =================
      // Controls only — the video surface is `videoLayer`, which has to outlive
      // this Loader for the sink to survive an Esc to browse. Gated on
      // `windowed` too: while the PiP owns the picture this window is not even
      // mapped, and the PiP draws its own whisper of a strip.
      Loader {
        id: theaterLoader
        anchors.fill: parent
        active: root.inTheater && root.windowed
        sourceComponent: theaterViewComponent
      }

      // ---------- resize bands ----------
      // startSystemResize turned out to exist alongside startSystemMove on
      // FloatingWindow (Qt::Edges parameter), so the four edges and four corners
      // each get a grab band. Declared last, and z-raised, so they win over the
      // content underneath — they only ever cover the outermost few pixels,
      // which the window's Style.space(14) content margin leaves empty anyway.
      // No threshold here: a press on an 8px edge band is unambiguous, and a
      // click that never moves simply ends the compositor's gesture immediately.
      // Hyprland's Super+RMB keeps working regardless; this is the mouse-only path.
      Item {
        id: resizeEdges
        anchors.fill: parent
        z: 100

        Repeater {
          model: [
            Qt.TopEdge, Qt.BottomEdge, Qt.LeftEdge, Qt.RightEdge,
            Qt.TopEdge | Qt.LeftEdge, Qt.TopEdge | Qt.RightEdge,
            Qt.BottomEdge | Qt.LeftEdge, Qt.BottomEdge | Qt.RightEdge
          ]

          MouseArea {
            required property var modelData
            readonly property int edges: Number(modelData)
            readonly property bool onTop: (edges & Qt.TopEdge) !== 0
            readonly property bool onBottom: (edges & Qt.BottomEdge) !== 0
            readonly property bool onLeft: (edges & Qt.LeftEdge) !== 0
            readonly property bool onRight: (edges & Qt.RightEdge) !== 0
            readonly property int band: Style.space(8)

            x: onLeft ? 0 : (onRight ? resizeEdges.width - band : band)
            y: onTop ? 0 : (onBottom ? resizeEdges.height - band : band)
            width: (onLeft || onRight) ? band : Math.max(0, resizeEdges.width - band * 2)
            height: (onTop || onBottom) ? band : Math.max(0, resizeEdges.height - band * 2)

            cursorShape: (onLeft || onRight)
              ? ((onTop || onBottom)
                ? (onTop === onLeft ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                : Qt.SizeHorCursor)
              : Qt.SizeVerCursor

            onPressed: appWindow.startSystemResize(edges)
          }
        }
      }
    }
  }

  // ================= video surface =================
  // The ONE thing that reparents. Everything else now belongs to exactly one
  // host: browse to the window, the PiP strip to the floaty surface.
  //
  // It deliberately does NOT live inside TheaterView, and it is deliberately
  // not built twice. player.videoOutput is a sink pointer QtMultimedia keeps
  // for the life of the session, so destroying this item — by putting it behind
  // the theater Loader, or by giving each surface its own copy — would pull the
  // sink out from under a running player every time you pressed Esc or hit the
  // PiP button. Moving a QQuickItem between QQuickWindows keeps the object (and
  // the sink) alive; only its scene-graph node is rebuilt.
  //
  // Full-bleed in both hosts: no margins, the background showing through the
  // letterbox bars.
  Item {
    id: videoLayer
    parent: root.windowed ? theaterSlot : pipSlot
    anchors.fill: parent
    // In the PiP the picture is the entire point, so it is never hidden there.
    visible: !root.windowed || root.inTheater

    VideoOutput {
      id: videoOut
      anchors.fill: parent
      visible: root.backend !== "mpv"
      fillMode: VideoOutput.PreserveAspectFit
    }
  }
}
