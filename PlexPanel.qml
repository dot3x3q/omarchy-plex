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

// Omarchy Plex panel entry point.
// Hosted by omarchy-shell; summoned with:
//   omarchy-shell shell toggle dot3x3q.omarchy-plex
// Config lives in ~/.config/omarchy-plex/config.json:
//   { "server": "http://host:32400", "token": "...", "backend": "internal" }
// backend "internal" (default): the video renders INSIDE this window, with the
//   theater strip over it. Which in-window engine draws it is a capability
//   question, not a preference — see the native-engine block below: with the
//   compiled PlexMpv module installed it is libmpv, and without it Qt's
//   QtMultimedia. The config value keeps its two names because they describe
//   where the picture goes, which is the only part the user chose.
// backend "mpv" (opt-in): playback launches in a standalone mpv window,
//   pinned bottom-right (--hwdec=auto --vo=gpu-next for dGPU decode, same
//   engine as plex-mpv-shim); the panel becomes the remote over mpv's IPC.
//
// The window draws no chrome of its own: Hyprland owns the frame, the drag
// and the resize, so an in-app title bar would only duplicate the compositor
// and steal 34px from every screen. The status banner, the header row's
// actions and the window `title:` property Hyprland's rules match on carry
// what a title bar would otherwise have held.
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
    root.service.paused = root.mode === "playing" && root.isPaused
    root.service.title = root.currentTitle
  }
  onServiceChanged: root.syncPlayerState()
  onCurrentTitleChanged: root.syncPlayerState()
  // mode/isPaused sync rides the theater handlers below — a second handler
  // for the same signal is a QML creation-time error, not an override.

  readonly property string pluginId: "dot3x3q.omarchy-plex"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/omarchy-plex"
  // Per-session socket name inside XDG_RUNTIME_DIR (0700); random suffix so a
  // stale socket from a crashed instance is never reused.
  readonly property string sockId: {
    var d = new Date()
    return "omarchy-plex-" + d.getTime().toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36)
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

  function applyConfig(raw) {
    if (raw.length > 4096) return
    var doc = JSON.parse(raw)
    var s = String(doc.server || "")
    var t = String(doc.token || "")
    if (Model.validServer(s)) root.server = s
    if (Model.validToken(t)) root.token = t
    if (doc.backend === "mpv") root.backend = "mpv"
  }

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
        try { root.applyConfig(String(text || "")) }
        catch (e) { /* first run or rejected file */ }
        if (!root.configured()) legacyConfigRead.running = true
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

  // Adopts a pre-rename install once. Read-only on the old paths — nothing
  // there is ever rewritten or removed — and adoption goes back out through
  // the normal save path, so the new location materializes on first run.
  readonly property string legacyConfigDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/plexmini"
  Process {
    id: legacyConfigRead
    running: false
    command: ["sh", "-c",
      "d='" + root.legacyConfigDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
      + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
      + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& dd if=config.json iflag=nofollow,nonblock bs=4097 count=1 status=none 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.applyConfig(String(text || "")) }
        catch (e) { /* nothing to adopt */ }
        if (root.configured()) root.saveConfig()
      }
    }
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

  // Video libraries from /library/sections: [{ id, title, type }]. The root
  // owns this so the debounced search box works from any page.
  property var libraries: []
  property var searchResults: []

  function setStatus(msg, urgent) {
    root.statusText = msg === undefined || msg === null ? "" : String(msg)
    root.statusUrgent = urgent === true
  }

  // session / progress-reporting state
  // The playing stream URL, kept for the native engine's surface handoff — a
  // new per-surface player has to reload the same stream at position.
  property string currentMediaUrl: ""
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
    // A banner describes the page that raised it; carrying "No results for X"
    // onto Home reads as a stuck error.
    root.setStatus("", false)
    root.setPanelCursor("page", "")
  }

  function goBack() {
    root.setStatus("", false)
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
    || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-plex"
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
  //
  // Native mode is deliberately NOT excluded here: mpvMode means the EXTERNAL
  // window, and the native engine draws in this one, so its picture reparents
  // into the card exactly as the VideoOutput does.
  readonly property bool pipAvailable: root.mode === "playing" && !root.mpvMode

  function enterPip() {
    if (!root.pipAvailable || !root.windowed) return
    // The PiP cannot host or dismiss the picker popups; one left open would
    // pin the strip over the video for the rest of the session.
    root.closeTrackPopup()
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
    // appWindow.screen is Qt's OPINION of the window's output, and on Wayland
    // that is a default rather than a fact: a window tiled on monitor three
    // still spawns its PiP on monitor one. The compositor is the only
    // authority on where a toplevel lives, so ask it; the answer lands after
    // the PiP maps, and reassigning screen then flows through onScreenChanged
    // -> bouncePipPlayer like any other move.
    pipHostQuery.running = true
    // The theater's native item dies with this flip (per-surface players —
    // see the crash note at the native block); capture what its successor in
    // the PiP must resume, and idle the outgoing core NOW — its destruction
    // races the window teardown, and a lost race leaks a playing audio thread
    // (NativeVideoHost.onDestruction is the second line of defense).
    if (root.nativeMode && root.mode === "playing") {
      root.pendingNativeArm = { pos: root.seekDisplayTime, paused: root.isPaused }
      if (root.nativeVideo) root.nativeVideo.stop()
    }
    root.windowed = false
    root.savePosition()
    root.pokeTheaterControls()
    root.focusPrimary()
  }

  function exitPip() {
    if (root.windowed) return
    if (root.nativeMode && root.mode === "playing") {
      root.pendingNativeArm = { pos: root.seekDisplayTime, paused: root.isPaused }
      if (root.nativeVideo) root.nativeVideo.stop()
    }
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
  // full-screen surface masked to a card, so without what follows the card is
  // trapped on whatever output the surface spawned on.
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
  // Live drag projection, driving the cross-monitor drop preview. The card
  // physically cannot follow the pointer past its surface's output — the
  // surface ends at the monitor border — so without a preview the gesture
  // reads as stuck and the drag gets released back on the origin monitor.
  // While the drag overshoots onto another output, a click-through ghost
  // overlay there draws the card outline at the exact drop point.
  property bool pipDragging: false
  property var pipDropScreen: null
  property real pipGhostX: 0
  property real pipGhostY: 0

  function updatePipDropPreview(sceneX, sceneY, grabX, grabY) {
    var cur = root.pipScreen
    var ox = cur ? cur.x : 0
    var oy = cur ? cur.y : 0
    var target = root.screenAtGlobal(ox + sceneX, oy + sceneY)
    if (!target || root.sameScreen(target, cur)) { root.pipDropScreen = null; return }
    // Same placement math as handlePipDrop, clamped into the target so the
    // preview shows where the card will actually LAND, not just the pointer.
    var localX = (ox + sceneX - grabX) - target.x
    var localY = (oy + sceneY - grabY) - target.y
    root.pipGhostX = Math.max(0, Math.min(target.width - root.videoWidth, localX))
    root.pipGhostY = Math.max(0, Math.min(target.height - root.videoHeight, localY))
    root.pipDropScreen = target
  }

  function adoptPipScreenByName(name) {
    var wanted = String(name || "").trim()
    if (wanted === "" || root.windowed) return
    var list = Quickshell.screens
    if (!list) return
    for (var i = 0; i < list.length; i++) {
      var scr = list[i]
      if (scr && String(scr.name) === wanted) {
        if (!root.sameScreen(scr, root.pipScreen)) {
          window.screen = scr
          root.clampMargins()
        }
        return
      }
    }
  }

  // Fixed pipeline, nothing interpolated: which output does the compositor
  // say the Omarchy Plex toplevel is on right now. Queried at PiP entry, while
  // the toplevel is still mapped and matchable by title.
  Process {
    id: pipHostQuery
    running: false
    command: ["sh", "-c",
      "m=$(hyprctl -j clients | jq -r 'first(.[] | select(.class==\"org.quickshell\" and (.title|endswith(\"Omarchy Plex\"))) | .monitor)'); "
      + "hyprctl -j monitors | jq -r --argjson m \"${m:-null}\" 'first(.[] | select(.id==$m) | .name) // empty'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptPipScreenByName(String(text || ""))
    }
  }

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

  // window.json is written whole, every time, so EVERY writer has to stage
  // every staged field — not just the one it thinks it owns. Two ways that
  // bites otherwise: posSave's staged fields hold construction defaults
  // (14/14/460/true) until something stages them, because positionRead loads
  // straight into root's properties, so the session's first writer can put
  // default geometry over the geometry just read off disk; and both resize
  // grips move the card's anchored margin as well as its width, so a resize
  // that staged only the width would pair it with a stale margin.
  //
  // volume and quality are bindings rather than staged fields for the same
  // reason. The rest cannot be: rebuilding the command string on every drag
  // frame is the cost the staging exists to avoid.
  function stageWindowState() {
    posSave.right = "" + Math.round(root.marginRight)
    posSave.bottom = "" + Math.round(root.marginBottom)
    posSave.width = "" + root.videoWidth
    posSave.windowed = root.windowed ? "true" : "false"
  }

  // One posSave run per save, never two: Quickshell latches a Process's argv at
  // start and silently ignores writes to a running one, so a second
  // running=true chasing the first would simply be dropped.
  function saveWidth() {
    root.stageWindowState()
    posSave.running = true
  }

  // Volume moves in 5% key steps and in slider drags, so the write is deferred
  // — one shell process per keystroke, or per frame, is not affordable.
  Timer {
    id: volumeSaveDebounce
    interval: 600
    repeat: false
    onTriggered: {
      root.stageWindowState()
      posSave.running = true
    }
  }

  function saveVolume() { volumeSaveDebounce.restart() }

  function savePosition() {
    root.stageWindowState()
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
    // Bound for the same reason as volume, and it moves even less often: a
    // quality pick is a deliberate act, not a drag.
    property string quality: "" + root.qualityKbps
    running: false
    command: ["sh", "-c",
      "d='" + root.stateDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
      + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
      + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& umask 077 && t=.window.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
      + "&& printf '{\"right\":%s,\"bottom\":%s,\"width\":%s,\"windowed\":%s,\"volume\":%s,\"quality\":%s}' "
      + posSave.right + " " + posSave.bottom + " " + posSave.width + " " + posSave.windowed
      + " " + posSave.volume + " " + posSave.quality
      + " > \"$t\" && chmod 600 \"$t\" && mv -f -- \"$t\" window.json && trap - EXIT"]
  }

  function applyWindowState(raw) {
    if (raw.length > 1024) return
    var doc = JSON.parse(raw)
    if (doc.right !== undefined) root.marginRight = Math.max(0, doc.right | 0)
    if (doc.bottom !== undefined) root.marginBottom = Math.max(0, doc.bottom | 0)
    if (doc.width !== undefined) root.videoWidth = Math.max(280, Math.min(3800, doc.width | 0))
    if (doc.volume !== undefined) root.volumePct = Math.max(0, Math.min(200, doc.volume | 0))
    // Only a value the tier list actually offers is accepted. This one ends up
    // substituted into a transcode URL, so "clamp it" is not good enough — an
    // unrecognised number falls back to Original.
    if (doc.quality !== undefined) {
      var want = doc.quality | 0
      root.qualityKbps = root.isQualityTier(want) ? want : 0
    }
    // Nothing is playing at load, and a PiP with no session shows no picture
    // and offers no way to start one — a persisted floaty always comes back as
    // the real window.
    if (doc.windowed !== undefined)
      root.windowed = doc.windowed === true || !root.pipAvailable
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
        var raw = String(text || "")
        try { root.applyWindowState(raw) } catch (e) { /* keep defaults */ }
        // Empty output means no readable new state file at all, which is the
        // only case an old one may speak for.
        if (raw === "") legacyPositionRead.running = true
      }
    }
  }

  // The state half of the pre-rename adoption; see legacyConfigRead.
  readonly property string legacyStateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/plexmini"
  Process {
    id: legacyPositionRead
    running: false
    command: ["sh", "-c",
      "d='" + root.legacyStateDir + "'; d=${d%/}; b=${d##*/}; "
      + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
      + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
      + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
      + "&& dd if=window.json iflag=nofollow,nonblock bs=1025 count=1 status=none 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw === "") return
        try { root.applyWindowState(raw) } catch (e) { return }
        root.savePosition()
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
      // isPaused already knows which of the three engines is live.
      root.wasPlayingBeforeLock = !root.isPaused
      if (root.backend === "mpv") mpvSend('{"command":["set_property","pause",true]}')
      else if (root.nativeMode) { if (root.nativeVideo) root.nativeVideo.paused = true }
      else player.pause()
    } else if (root.wasPlayingBeforeLock) {
      if (root.backend === "mpv") mpvSend('{"command":["set_property","pause",false]}')
      else if (root.nativeMode) { if (root.nativeVideo) root.nativeVideo.paused = false }
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
    } else {
      pollTimer.restart()
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
    } else if (root.nativeMode) {
      // Guarded on mode for the same reason the mpv branch is, and for one
      // more: mpv's pause property outlives the file, so pausing an idle core
      // would make the NEXT item load paused. (startNative clears it anyway —
      // belt and braces, because this is the path that sets it.)
      if (root.mode === "playing" && root.nativeVideo) root.nativeVideo.paused = true
    } else if (player.playbackState === MediaPlayer.PlayingState) {
      player.pause()
    }
    if (root.mode === "playing") sendTimeline("paused")
    // A closed panel has nothing to poll for: on mpv this timer spawns a
    // sh+socat every second, and both backends keep posting timeline pings
    // for a session nobody is watching. open() restarts it.
    pollTimer.stop()
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
  // library, and an unbounded fan-out gets the server rate-limiting and the
  // process table churning; four in flight stays civil and still saturates a
  // LAN Plex.
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
      if (doc === null && root.configured())
        root.setStatus("Plex request failed — check server, token and network", true)
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
      // A slow response can land after the user navigated away; its banner
      // belongs to the search page, not to wherever they are now. And a null
      // doc is a transport/auth failure, not an empty library — say so, or a
      // dead server renders as a perfectly normal empty app.
      if (root.currentPage !== "search") return
      if (doc === null) root.setStatus("Plex request failed — check server, token and network", true)
      else root.setStatus(out.length === 0 ? "No results for “" + query + "”" : "", false)
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
      // Only QtMultimedia needs the token on the URL: its media loader cannot
      // send an HTTP header at all, which is the documented exception the
      // artwork URLs share. Both mpv engines carry it in a header instead, so
      // in native mode this direct-play URL is clean — no token in the string
      // handed to the demuxer, none in any log line that quotes it.
      if (root.backend !== "mpv" && !root.nativeMode)
        mediaUrl += "?X-Plex-Token=" + root.token
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
    root.closeTrackPopup()
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
      // Property polling is EXTERNAL-mpv only: that backend has no way to push
      // and this timer is its 1 s heartbeat over socat. The native engine
      // publishes time-pos/duration/pause through NOTIFY signals, and the
      // internal one through Qt's own bindings — but the timer still runs for
      // all three, because the scrobble threshold and the 10 s timeline reports
      // below are the timer's real job.
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
          : (root.nativeMode ? root.isPaused
            : player.playbackState === MediaPlayer.PausedState)
        sendTimeline(paused ? "paused" : "playing")
      }
    }
  }

  // Mute belongs to the internal backend's AudioOutput, which is file-scope
  // here; the theater strip is a separate file, so it gets these instead.
  // Native mode has its own mute, on the mpv core rather than on Qt's
  // AudioOutput — the strip's speaker glyph reads whichever engine is live.
  readonly property bool audioMuted: root.nativeMode
    ? (root.nativeVideo ? root.nativeVideo.muted === true : false)
    : audio.muted

  function toggleMute() {
    if (root.mpvMode) return
    if (root.nativeMode) {
      if (root.nativeVideo) root.nativeVideo.muted = !root.nativeVideo.muted
      return
    }
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

  // ---- magnetic detents ----
  //
  // Free movement everywhere, but a value landing within volumeDetentPull of a
  // notch is pulled onto it. 100 is the one that actually matters — it is the
  // line where Qt's own ceiling stops and the PipeWire boost starts — and
  // hitting it by aim on a 150px vertical track is a 1-in-13 shot.
  readonly property var volumeDetents: [0, 50, 100, 150, 200]
  readonly property int volumeDetentPull: 8
  // Deliberately LARGER than the pull. A relative step smaller than the pull
  // can never escape a detent — 100 - 5 snaps straight back to 100 — so the
  // notch would become a trap the wheel could not leave. Drags set an absolute
  // value from the pointer, so they need no such allowance and keep the pull.
  readonly property int volumeWheelStep: 10

  function snapVolumePct(pct) {
    var v = Math.max(0, Math.min(200, Math.round(Number(pct) || 0)))
    for (var i = 0; i < root.volumeDetents.length; i++)
      if (Math.abs(v - root.volumeDetents[i]) <= root.volumeDetentPull)
        return root.volumeDetents[i]
    return v
  }

  // Every pointer-driven volume write goes through here; the keyboard's ±5
  // steps deliberately do not, because that grid already lands on every notch
  // exactly and snapping it would only make 95 and 105 unreachable.
  function setVolumeSnapped(pct) { root.setVolumePct(root.snapVolumePct(pct)) }

  function nudgeVolumeWheel(up) {
    root.setVolumeSnapped(root.volumePct + (up ? root.volumeWheelStep : -root.volumeWheelStep))
  }

  // ---- the volume popup ----
  //
  // A vertical slider that hangs above the mute button rather than sitting
  // inline, where it would cost the theater strip ~120px of width for a control
  // wanted a second at a time. It stays up while the pointer is on the button
  // OR on the popup; the grace period is what lets the diagonal traverse
  // between the two cross the gap without the popup vanishing underneath it.
  //
  // The keyboard reaches it through volumeAdjusting rather than the panel
  // cursor: ↑/↓ is the only keyboard route to the volume in theater (there is
  // no cursor walk along the strip), so a key step brings the whole popup up
  // with the reading.
  //
  // Theater only (volumePopupVisible requires `windowed`). The PiP strip has
  // a mute button now, but the popup still cannot hang off it: the floaty's
  // input mask stops at pipCard, so a popup overhanging the card would be
  // visible but mouse-dead. That surface gets wheel-over-the-picture and a
  // readout chip instead.
  property bool volumePopupHeld: false

  readonly property bool volumePopupVisible: root.inTheater && root.windowed
    && !root.mpvMode && (root.volumePopupHeld || root.volumeAdjusting)

  Timer {
    id: volumePopupGrace
    interval: 300
    repeat: false
    onTriggered: root.volumePopupHeld = false
  }

  // Both edges matter. Opening pins the strip (pokeTheaterControls STOPS the
  // hide timer while the popup is up, so the slider cannot fade out from under
  // a drag); closing has to hand that timer back, or the chrome sits over the
  // film indefinitely. Hanging this off the derived property rather than off
  // the grace timer covers every route out — the hold expiring, volumeAdjusting
  // expiring 1500ms after the last key step, or leaving theater entirely.
  onVolumePopupVisibleChanged: root.pokeTheaterControls()

  function holdVolumePopup() {
    volumePopupGrace.stop()
    root.volumePopupHeld = true
    root.pokeTheaterControls()
  }

  function releaseVolumePopup() { volumePopupGrace.restart() }

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

  // Only QtMultimedia needs this. Both mpv engines do their own gain above
  // unity (volume-max=200), so boosting the graph under them would multiply the
  // two and leave every other quickshell stream loud for no reason at all.
  readonly property bool volumeBoostActive: root.opened
    && !root.sessionLocked
    && root.mode === "playing"
    && root.backend !== "mpv"
    && !root.nativeMode
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
  onQuickshellStreamsChanged: root.applyStreamBoost()
  onVolumePctChanged: {
    // The native item takes the whole 0–200 scale directly, in-process, so it
    // needs neither the boost below nor the external backend's 120 ms coalescer
    // (that timer exists to avoid one socat per drag frame; this is a property
    // write). A second handler for this signal would be a creation-time error,
    // so the boost call stays here rather than getting one of its own.
    if (root.nativeMode && root.nativeVideo) root.nativeVideo.volume = root.volumePct
    root.applyStreamBoost()
  }

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
    // The native item has no cycle command; its paused property is the observed
    // mpv one, so reading it back is reading mpv's actual state.
    else if (root.nativeMode) { if (root.nativeVideo) root.nativeVideo.paused = !root.nativeVideo.paused }
    else if (player.playbackState === MediaPlayer.PlayingState) player.pause()
    else player.play()
  }

  function seekRel(seconds) {
    if (root.backend === "mpv") mpvSend('{"command":["seek",' + seconds + ']}')
    else if (root.nativeMode) { if (root.nativeVideo) root.nativeVideo.seekRelative(seconds) }
    else player.position = Math.max(0, player.position + seconds * 1000)
  }

  function seekAbs(fraction) {
    if (root.backend === "mpv") {
      if (root.dispDuration <= 0) return
      mpvSend('{"command":["set_property","time-pos",' + (fraction * root.dispDuration).toFixed(1) + ']}')
    } else if (root.nativeMode) {
      // The native API takes seconds, not a fraction — the callers all speak
      // fractions because that is what a slider produces.
      if (root.dispDuration <= 0 || !root.nativeVideo) return
      root.nativeVideo.seekAbsolute(fraction * root.dispDuration)
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
  // strip out from under a list the user is reading would be absurd. The volume
  // popup hangs off the mute button the same way and pins it for the same
  // reason — it would otherwise fade out from under an active drag.
  readonly property bool theaterControlsVisible: root.theaterControlsShown
    || root.isPaused || root.trackPopup !== "" || root.volumePopupVisible

  Timer {
    id: theaterHideTimer
    interval: 2000
    repeat: false
    onTriggered: root.theaterControlsShown = false
  }

  function pokeTheaterControls() {
    root.theaterControlsShown = true
    if (root.inTheater && !root.isPaused && root.trackPopup === "" && !root.volumePopupVisible)
      theaterHideTimer.restart()
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
  //    failure an hour from now — is muxed from the right tracks. It answers
  //    200 with an empty body, needs no client-identifier header, takes the
  //    audio and subtitle params independently, and reads subtitleStreamID=0
  //    as "none".
  //  - Direct play on the internal backend then also moves the PLAYER's own
  //    active track, which is what makes the change audible immediately.
  //  - mpv gets an IPC property write, by ordinal.
  //
  // Anything the live pipeline cannot do itself falls back to asking the
  // server for a new stream — see rowNeedsServer.
  property var audioStreams: []
  property var subtitleStreams: []
  property string currentPartId: ""
  // The part's media key, kept so a quality switch back to Original can rebuild
  // the direct-play URL. Stashed off the resolve response the panel already
  // has, rather than costing a second round trip.
  property string currentPartKey: ""
  // Plex stream ids, as strings. "" on the subtitle side means "none".
  property string selectedAudioId: ""
  property string selectedSubtitleId: ""

  readonly property bool audioPickerAvailable: root.mode === "playing" && root.audioStreams.length > 1
  readonly property bool subtitlePickerAvailable: root.mode === "playing" && root.subtitleStreams.length > 0

  // Model.parsePlaybackMetadata knows only about playback, but the resolve body
  // already carries the whole Stream list, so the tracks are read straight out
  // of that response.
  function stashStreams(jsonText) {
    var parsed = null
    var partKey = ""
    try {
      var doc = JSON.parse(jsonText)
      parsed = Api.mapStreams(doc)
      // Api.mapStreams reports the part's ID (what the selection PUT addresses)
      // but not its key (what a direct play fetches), and both come off this
      // one response.
      var mc = doc && doc.MediaContainer
      var meta = mc && mc.Metadata && mc.Metadata.length > 0 ? mc.Metadata[0] : null
      var media = meta && meta.Media && meta.Media.length > 0 ? meta.Media[0] : null
      var part = media && media.Part && media.Part.length > 0 ? media.Part[0] : null
      partKey = part ? String(part.key || "") : ""
    } catch (e) { parsed = null; partKey = "" }
    root.currentPartKey = partKey
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
  // Native mode is excluded outright rather than left to fall out of the
  // mediaStatus test: `player` never gets a source there, so everything
  // downstream of this (alignment, player-supplied labels, the Qt default-track
  // fix) is meaningless and must not be consulted.
  readonly property bool playerTracksReady: root.backend !== "mpv"
    && !root.nativeMode
    && (player.mediaStatus === MediaPlayer.LoadedMedia
      || player.mediaStatus === MediaPlayer.BufferedMedia
      || player.mediaStatus === MediaPlayer.BufferingMedia)

  // Qt plays the container's DEFAULT track, not the one Plex has selected —
  // an anime opens dubbed in Japanese while the picker truthfully shows
  // English as selected. Once the demuxer is up and
  // the lists align, push Plex's selection into the pipeline. Re-fires per
  // source, which is also correct after a user pick: selectedAudioId tracks
  // the latest choice. Skipped for transcodes — the choice is muxed in.
  function findStream(kind, streamId) {
    var streams = kind === "audio" ? root.audioStreams : root.subtitleStreams
    for (var i = 0; i < streams.length; i++)
      if (streams[i] && String(streams[i].id) === String(streamId)) return streams[i]
    return null
  }

  function applyPlexSelectedTracks() {
    // Qt only. The native engine has the same problem and a different answer —
    // see applyNativeSelectedTracks, which fires off fileLoaded() instead of
    // off a mediaStatus poll.
    if (root.mpvMode || root.nativeMode) return
    if (root.triedTranscode || !root.playerTracksReady) return
    if (root.selectedAudioId !== "" && root.playerTracksAligned("audio")) {
      var a = root.findStream("audio", root.selectedAudioId)
      if (a && a.external !== true) root.setPlayerAudioTrack(Number(a.ordinal))
    }
    if (root.playerTracksAligned("subtitle")) {
      var sub = root.selectedSubtitleId === ""
        ? null : root.findStream("subtitle", root.selectedSubtitleId)
      // An image or sidecar selection needs the server; starting playback is
      // not the moment to force a transcode, so those stay unapplied until
      // the user asks through the picker.
      if (sub === null) root.setPlayerSubtitleTrack(-1)
      else if (sub.external !== true && sub.image !== true)
        root.setPlayerSubtitleTrack(Number(sub.ordinal))
    }
  }

  onPlayerTracksReadyChanged: if (root.playerTracksReady) Qt.callLater(root.applyPlexSelectedTracks)

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
    // "quality" rides this same popup rather than growing a second one: the row
    // contract the list widget reads (label + current) is identical, and so are
    // the key dispatcher, the scrim and the Esc ordering. Only what a pick DOES
    // differs, which is one branch in activatePickerRow.
    if (kind === "quality") return root.qualityRows()
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
    // Either mpv — the external window or the in-window native item — draws
    // anything that is muxed, image subtitles included, so no muxed track ever
    // costs a burn-in transcode on those engines.
    if (root.mpvMode || root.nativeMode) return false
    // Qt's ffmpeg backend only ever reads a subtitle rect's TEXT payload; the
    // bitmap one is never touched, so a PGS or VOBSUB track cannot be drawn
    // in-window at all and the server has to burn it into the picture. Not a
    // corner case: a film often ships several image tracks and one text one.
    if (kind === "subtitle" && row.image === true) return true
    return !root.playerTracksAligned(kind)
  }

  // The picker's "burn-in" caption, kept honest by construction. It is exactly
  // the case where a MUXED image subtitle forces a server round trip — a
  // QtMultimedia-only limitation, since both mpv engines draw PGS and VOBSUB
  // themselves. Derived from rowNeedsServer rather than restating its
  // condition in the delegate, because a warning about the more expensive
  // outcome is precisely the thing that must not drift from the decision.
  function rowBurnsIn(row) {
    return row !== null && row !== undefined
      && row.image === true && row.external !== true
      && root.rowNeedsServer("subtitle", row)
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

  // ---- the mpv side of the same job ----
  //
  // One ordinal contract, two transports. Both mpv engines number tracks from 1
  // per type in container order — the same order Plex lists its streams in,
  // which is what `ordinal` counts — so callers add 1 to a Plex ordinal and
  // pass anything below 1 to mean "none". The native item takes the number
  // through an invokable; the external one gets it over IPC.
  function setMpvAudioTrack(ordinal) {
    if (root.nativeMode) {
      if (root.nativeVideo) root.nativeVideo.setAudioTrack(ordinal)
      return
    }
    root.mpvSend('{"command":["set_property","aid",' + ordinal + ']}')
  }

  function setMpvSubtitleTrack(ordinal) {
    if (root.nativeMode) {
      // mpvvideo.cpp turns anything < 1 into mpv's "no" itself.
      if (root.nativeVideo) root.nativeVideo.setSubtitleTrack(ordinal)
      return
    }
    if (ordinal < 1) { root.mpvSend('{"command":["set_property","sid","no"]}'); return }
    root.mpvSend('{"command":["set_property","sid",' + ordinal + ']}')
  }

  // The native sibling of applyPlexSelectedTracks, and it exists for the same
  // reason: mpv, like Qt, opens the container's DEFAULT track rather than the
  // one Plex has selected, so a dubbed film starts in the wrong language while
  // the picker truthfully shows the right one.
  //
  // Simpler than the Qt version in three ways. fileLoaded() IS the readiness
  // signal, so there is no mediaStatus dance. There is no alignment test,
  // because the ordinals address the same demuxer Plex enumerated rather than a
  // second pipeline's idea of the track list. And an IMAGE subtitle is applied
  // here where the Qt path has to leave it alone — libmpv renders PGS and
  // VOBSUB, so honouring that selection costs nothing, whereas on Qt it would
  // silently force a burn-in transcode at the moment playback starts.
  function applyNativeSelectedTracks() {
    if (!root.nativeMode || !root.nativeVideo) return
    // A transcode is already muxed to the chosen tracks and carries exactly one
    // of each, so ordinals counted off the ORIGINAL file would miss.
    if (root.triedTranscode) return
    if (root.selectedAudioId !== "") {
      var a = root.findStream("audio", root.selectedAudioId)
      if (a && a.external !== true) root.setMpvAudioTrack(Number(a.ordinal) + 1)
    }
    var sub = root.selectedSubtitleId === ""
      ? null : root.findStream("subtitle", root.selectedSubtitleId)
    // A sidecar file is in no container, so no ordinal addresses it; that one
    // still needs the server, and only if the user asks through the picker.
    if (sub === null) root.setMpvSubtitleTrack(-1)
    else if (sub.external !== true) root.setMpvSubtitleTrack(Number(sub.ordinal) + 1)
  }

  function activateTrackRow(kind, row) {
    if (!row) return
    var needsServer = root.rowNeedsServer(kind, row)
    root.closeTrackPopup()
    if (kind === "audio") root.selectedAudioId = String(row.streamId || "")
    else root.selectedSubtitleId = String(row.streamId || "")

    // Both mpv engines take the same route: flip the track in the running
    // pipeline by ordinal, then tell the server what was chosen so a transcode
    // started later is muxed from it. Best-effort by construction — there is no
    // cheap readback to confirm the mux order matched, so a file whose
    // container order disagreed with Plex's would pick the neighbouring track.
    if (root.mpvMode || root.nativeMode) {
      if (needsServer) { root.putTrackSelection(true); return }
      if (kind === "audio") root.setMpvAudioTrack(Number(row.ordinal) + 1)
      else root.setMpvSubtitleTrack(row.none === true ? -1 : Number(row.ordinal) + 1)
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

  // ---- stream quality ----
  //
  // 0 means "Original" — direct play, the server hands over the file and
  // nothing is re-encoded. Anything else is a kbps cap that FORCES the
  // transcode path even when the file would have played directly, which is the
  // whole point over a thin link. Persisted in window.json beside volumePct.
  //
  // THREE params, not two, and that is the whole subtlety here. Cross-checked
  // against the Plex API spec, the Plex Web bundle, plex-for-kodi's plexnet
  // and Tautulli:
  //
  //  - maxVideoBitrate is in kbps.
  //  - videoQuality is Plex's own 0–100 encoder-quality knob — NOT a ladder
  //    index. (The server root's transcoderVideoQualities="0,1,…,12" is a slot
  //    list and is the source of that confusion; python-plexapi overloads the
  //    name too, taking the index in optimize() and the wire value elsewhere.)
  //  - videoResolution is an INDEPENDENT cap. A bitrate cap on its own does not
  //    downscale anything — it squeezes the source resolution into fewer bits.
  //    Every official client sends all three, and plexnet computes the
  //    resolution client-side and sends it explicitly, which would be dead
  //    weight if the server inferred it. So a tier that says 720p has to SAY
  //    720p, or the label is a lie and the picture is just a mushier 4K frame.
  //
  // quality/resolution pairings are Plex's own ladder where the rungs line up
  // (12000→90, 8000→60, 4000→100, 2000→60). The 4K and 480p rungs are ours:
  // Plex's named ladder tops out at 20 Mbps 1080p and has no 480p tier, but
  // videoResolution is a free-form cap and 4K sources are ordinary now.
  property int qualityKbps: 0

  readonly property var qualityTiers: [
    { kbps: 0,     quality: 0,   resolution: "",          label: "Original (direct play)" },
    { kbps: 20000, quality: 100, resolution: "3840x2160", label: "20 Mbps · 4K" },
    { kbps: 12000, quality: 90,  resolution: "1920x1080", label: "12 Mbps · 1080p" },
    { kbps: 8000,  quality: 60,  resolution: "1920x1080", label: "8 Mbps · 1080p" },
    { kbps: 4000,  quality: 100, resolution: "1280x720",  label: "4 Mbps · 720p" },
    { kbps: 2000,  quality: 60,  resolution: "720x480",   label: "2 Mbps · 480p" }
  ]

  readonly property bool qualityPickerAvailable: root.mode === "playing"

  function qualityRows() {
    var rows = []
    for (var i = 0; i < root.qualityTiers.length; i++) {
      var t = root.qualityTiers[i]
      rows.push({
        label: String(t.label),
        kbps: Number(t.kbps),
        current: Number(t.kbps) === root.qualityKbps,
        // The picker delegate reads these to decide whether to draw its
        // "server"/"burn-in" hint. Quality rows always restart, so neither
        // caption would tell the user anything they did not just ask for.
        external: false,
        image: false,
        none: false
      })
    }
    return rows
  }

  function qualityForKbps(kbps) {
    for (var i = 0; i < root.qualityTiers.length; i++)
      if (Number(root.qualityTiers[i].kbps) === Number(kbps))
        return Number(root.qualityTiers[i].quality)
    return 60
  }

  function resolutionForKbps(kbps) {
    for (var i = 0; i < root.qualityTiers.length; i++)
      if (Number(root.qualityTiers[i].kbps) === Number(kbps))
        return String(root.qualityTiers[i].resolution || "")
    return ""
  }

  // Membership, not clamping. qualityForKbps answers with its 60 fallback for
  // anything it does not know, so it cannot be used to validate a number read
  // off disk that is about to be substituted into a URL.
  function isQualityTier(kbps) {
    for (var i = 0; i < root.qualityTiers.length; i++)
      if (Number(root.qualityTiers[i].kbps) === Number(kbps) && Number(kbps) > 0) return true
    return false
  }

  // What transcodeUrl actually emits. A chosen tier wins everywhere — including
  // over a codec-failure fallback that fires an hour later — but with no tier
  // chosen these stay on 6000/60, the automatic fallback's own constants.
  // Picking Original does NOT soften the fallback: a direct play that dies
  // still has to land somewhere.
  readonly property int transcodeBitrateKbps: root.qualityKbps > 0 ? root.qualityKbps : 6000
  readonly property int transcodeVideoQuality: root.qualityKbps > 0
    ? root.qualityForKbps(root.qualityKbps) : 60
  // Empty with no tier chosen, and transcodeUrl then omits the param entirely,
  // so the automatic codec-failure fallback sends the unconstrained query.
  // Only a deliberate pick adds a resolution cap.
  readonly property string transcodeResolution: root.qualityKbps > 0
    ? root.resolutionForKbps(root.qualityKbps) : ""

  function saveQuality() { volumeSaveDebounce.restart() }

  function activateQualityRow(row) {
    if (!row) return
    root.closeTrackPopup()
    var next = Math.max(0, Number(row.kbps) || 0)
    if (next === root.qualityKbps) return
    root.qualityKbps = next
    root.saveQuality()
    root.beginQualityRestart()
  }

  // Same shape as beginTrackRestart — take the position, park it in resumeSec,
  // replay through the path the choice implies — and for any TIER it is
  // literally that function: the tier is already baked into transcodeUrl by the
  // two properties above, so the transcode restart needs no other change.
  //
  // Original is the case beginTrackRestart cannot express, because it always
  // goes to the transcoder. That path replays the direct part URL instead and
  // clears triedTranscode, so the codec fallback is armed again for a stream
  // that is genuinely direct-playing.
  function beginQualityRestart() {
    if (root.currentRatingKey === "" || root.mode !== "playing") return
    if (root.qualityKbps > 0) {
      root.setStatus("Switching quality — restarting the stream…", false)
      root.beginTrackRestart()
      return
    }
    if (root.currentPartKey === "") {
      // No stashed part key (a session resumed from a response we never
      // parsed): a full re-resolve is the honest fallback, at the cost of
      // rejoining at the server's last reported offset rather than this one.
      root.setStatus("Switching to direct play…", false)
      root.playItem(root.currentRatingKey, root.currentTitle)
      return
    }
    root.setStatus("Switching to direct play — restarting the stream…", false)
    root.resumeSec = Math.max(0, Math.round(root.seekDisplayTime))
    root.triedTranscode = false
    root.playGen++
    root.clearSeekPreview()
    // Same URL construction as applyMetadata, including the reason only the
    // QtMultimedia path appends a token: its media loader cannot send headers.
    var url = root.server + root.currentPartKey
    if (root.backend !== "mpv" && !root.nativeMode)
      url += "?X-Plex-Token=" + root.token
    if (root.backend === "mpv") root.startMpv(url)
    else root.startInternal(url)
  }

  // ---- the picker itself ----
  //
  // A plain list drawn on the theater overlay rather than a QQC2 Popup. It
  // needs no focus scope and no Shortcut objects of its own: the existing
  // dispatcher simply gives it first refusal while it is open, which is what
  // keeps it out of the layered-Esc chain's way instead of competing with it.
  property string trackPopup: "" // "" | "audio" | "subtitle" | "quality"
  property int trackPopupIndex: 0

  // One entry point for both the list's click and the keyboard's Enter, so the
  // two can never diverge on what a row does. Track picks keep going through
  // activateTrackRow (PUT first, restart only off its exit); quality picks
  // never touch the part selection, so they take their own path.
  function activatePickerRow(kind, row) {
    if (kind === "quality") { root.activateQualityRow(row); return }
    root.activateTrackRow(kind, row)
  }

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
    root.activatePickerRow(kind, rows[root.trackPopupIndex])
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
    if (text === "q" && root.qualityPickerAvailable) { root.toggleTrackPopup("quality"); return true }
    return true
  }

  function finishPlayback() {
    sendTimeline("stopped")
    pollTimer.stop()
    // A picker left open by the ended session would otherwise keep first
    // refusal on every key while the user is back in browse.
    root.closeTrackPopup()
    root.mode = "list"
    root.currentTitle = ""
    root.currentThumbPath = ""
    root.currentMediaUrl = ""
    root.pendingNativeArm = null
    root.clearSeekPreview()
    root.setPanelCursor("page", "")
  }

  function stop() {
    root.userStop = true
    if (root.backend === "mpv") {
      mpvQuit.running = true
      finishPlayback()
    } else if (root.nativeMode) {
      // mpv's end-file reason for this is "stop", which mpvvideo.cpp ignores
      // deliberately: a user-initiated stop is neither an EOF nor a failure, so
      // it cannot trip the transcode fallback on the way out. The core stays
      // idle and reusable for the next item.
      if (root.nativeVideo) root.nativeVideo.stop()
      finishPlayback()
    } else {
      player.stop()
      player.source = ""
      finishPlayback()
    }
  }

  // ---- native backend: libmpv, rendered in-window ----
  //
  // A THIRD engine, and the only one nobody selects. `backend` still means
  // "where does the picture go" — in this window, or in mpv's own — and the
  // in-window slot is filled by whichever engine is actually available:
  // libmpv when the compiled PlexMpv module is installed, QtMultimedia when it
  // is not. That auto-upgrade is why there is no third config value to pick and
  // no setting to get wrong.
  //
  // Why prefer it: QtMultimedia's sink does no HDR tone mapping (4K DoVi plays
  // with crushed blacks and clipped highlights) and drops to software decode on
  // NVIDIA. It also cannot send an HTTP header, which is why the QtMultimedia
  // path has to hang the Plex token off the media URL. libmpv fixes all three.
  //
  // The QtMultimedia path is NOT legacy and must not be removed. MpvQt's item
  // is a QQuickFramebufferObject, which is OpenGL-only by Qt's own
  // documentation — a shell running QSG_RHI_BACKEND=vulkan would load this
  // module successfully and then render nothing. See NativeVideoHost.qml.
  // Availability comes from a windowless probe (import-only, no mpv core);
  // the live player is whichever per-surface Loader is active. ONE MpvVideo
  // must never move between QQuickWindows: the FBO's render context dies with
  // the swap and the next render call locks a freed mutex —
  // mpv_render_context_render → pthread_mutex_lock, SIGSEGV, taking the whole
  // shell with it. So each surface owns its own item and a surface switch is a
  // deliberate reload-at-position handoff.
  readonly property bool nativeReady: nativeProbe.status === Loader.Ready
  readonly property var nativeVideo: root.windowed ? theaterNativeLoader.item : pipNativeLoader.item
  readonly property bool nativeMode: root.backend === "internal" && root.nativeReady

  Loader {
    id: nativeProbe
    asynchronous: false
    source: "NativeProbe.qml"
    width: 0; height: 0
  }

  // What the next-created native item should do the moment it exists: either a
  // fresh play (from startNative racing its own Loader activation) or a
  // surface handoff (position and pause state captured before the flip).
  property var pendingNativeArm: null

  // Reassigning window.screen recreates the SURFACE under the same item
  // (Quickshell hides, moves, shows — and a hidden layer surface is deleted),
  // which kills the render context exactly like a reparent would: black
  // picture, audio marching on. So any
  // screen change of the PiP while native video is up bounces the player
  // through the same reload-at-position handoff a surface flip uses.
  property bool pipPlayerBounce: false

  function bouncePipPlayer() {
    if (root.windowed || !root.nativeMode || root.mode !== "playing") return
    if (root.pipPlayerBounce) return
    // screenChanged also fires when the surface FIRST maps (mapping assigns
    // the output), and that must not stomp the arm the surface flip staged: it
    // would capture position 0 off the brand-new player and restart the film
    // from the beginning. An arm already staged wins, and a player with no
    // duration yet has no position worth capturing.
    if (root.pendingNativeArm !== null) return
    var v = root.nativeVideo
    if (!v || !(v.duration > 0)) return
    root.pendingNativeArm = { pos: root.seekDisplayTime, paused: root.isPaused }
    v.stop()
    root.pipPlayerBounce = true
    Qt.callLater(function() { root.pipPlayerBounce = false })
  }

  function armNativePlayback() {
    var v = root.nativeVideo
    var arm = root.pendingNativeArm
    if (!v || !arm || root.currentMediaUrl === "") return
    root.pendingNativeArm = null
    v.httpHeaders = ["X-Plex-Token: " + root.token]
    v.volume = root.volumePct
    v.paused = false
    v.loadUrl(root.currentMediaUrl, Math.max(0, Number(arm.pos) || 0))
    // mpv applies a pause set during load before the first frame, so a
    // handoff out of a paused theater lands paused in the PiP too.
    if (arm.paused === true) v.paused = true
  }

  function startNative(url) {
    // Headers ride a property, not a URL or argv — the security win. The
    // resume point rides loadUrl as mpv's `start` property, applied before the
    // first frame, so the resumeRetry ladder below has nothing to do here.
    root.currentMediaUrl = url
    root.pendingNativeArm = { pos: root.resumeSec, paused: false }
    root.resumeSec = 0
    root.setStatus("", false)
    // Setting mode activates this surface's Loader; if the item already
    // exists (replaying, or a transcode restart) arm right away, otherwise
    // the Loader's onLoaded consumes the pending arm.
    root.mode = "playing"
    if (root.nativeVideo) root.armNativePlayback()
  }

  // mpv's own event stream, arriving on the GUI thread. endReached is a real
  // EOF and playbackFailed is a decode/transport error — the C++ swallows the
  // "stop" and "quit" reasons, so root.stop() cannot trip the transcode ladder.
  Connections {
    target: root.nativeVideo
    enabled: root.nativeMode

    function onFileLoaded() { root.applyNativeSelectedTracks() }
    function onEndReached() { if (root.mode === "playing") root.finishPlayback() }
    // Same entry point as every other engine's failure, so the direct-play →
    // server-transcode ladder is shared rather than reimplemented.
    function onPlaybackFailed(reason) { if (root.mode === "playing") root.playbackFailed() }
  }

  // ---- internal backend (fallback) ----
  function startInternal(url) {
    // The in-window engine auto-upgrades (see the native block above): when the
    // module is there, "internal" plays through libmpv and QtMultimedia is
    // never touched.
    if (root.nativeMode) { root.startNative(url); return }
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
      // QtMultimedia only. libmpv applies the resume point as its `start`
      // property before the first frame, so there is nothing here to retry —
      // and player is not even the live engine to ask.
      if (root.nativeMode) { stop(); return }
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
    // Get any of these three wrong and the server answers a bare 400:
    //  - "path" must be lowercase; "Path" is rejected outright.
    //  - X-Plex-Platform is REQUIRED in the query — the server derives its
    //    whole transcode client profile from it. "Chrome" gets the h264/aac
    //    HLS ladder QtMultimedia's ffmpeg handles, and is what python-plexapi
    //    sends for the same reason.
    //  - X-Plex-Client-Identifier in THIS query is the one param that turns a
    //    200 into a 400 (it collides with the device record our header-borne
    //    identifier registered) — so uniquely here, it stays out.
    return root.server + "/video/:/transcode/universal/start.m3u8"
      + "?path=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
      + "&mediaIndex=0&partIndex=0&protocol=hls&fastSeek=1"
      + "&directPlay=0&directStream=0&hasMDE=1"
      + "&videoQuality=" + root.transcodeVideoQuality
      + "&maxVideoBitrate=" + root.transcodeBitrateKbps
      + (root.transcodeResolution === ""
        ? "" : "&videoResolution=" + root.transcodeResolution)
      + "&audioBoost=100&subtitleSize=100"
      + "&session=" + root.sessionId
      + "&X-Plex-Platform=Chrome"
      + "&X-Plex-Token=" + root.token
      + "&X-Plex-Product=Omarchy%20Plex"
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
        .concat([root.server + "/:/timeline?ratingKey=" + encodeURIComponent(root.currentRatingKey)
        + "&key=" + encodeURIComponent("/library/metadata/" + root.currentRatingKey)
        + "&duration=" + Math.round(root.dispDuration * 1000)
        + "&time=" + Math.round(root.dispTime * 1000)
        + "&state=" + state
        + "&hasMDE=1&identifier=com.plexapp.plugins.library"
        + "&X-Plex-Client-Identifier=" + root.pluginId
        + "&X-Plex-Product=Omarchy%20Plex&X-Plex-Device-Name=OmarchyPlex"])
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
  //
  // Three engines, one set of numbers. Everything downstream reads these and
  // nothing else: the seek-ack loop, both scrubbers, the minibar clock, the
  // scrobble threshold and the timeline reports. The native readings arrive on
  // mpv's own event stream through NOTIFY signals rather than the external
  // backend's 1 s socat poll, so they update at mpv's rate for free.
  readonly property bool mpvMode: root.backend === "mpv" && root.mode === "playing"
  readonly property real dispTime: root.mpvMode
    ? root.mpvTime
    : (root.nativeMode ? (root.nativeVideo ? root.nativeVideo.timePos : 0)
      : player.position / 1000)
  readonly property real dispDuration: root.mpvMode
    ? root.mpvDuration
    : (root.nativeMode ? (root.nativeVideo ? root.nativeVideo.duration : 0)
      : player.duration / 1000)
  readonly property bool isPaused: root.mpvMode
    ? root.mpvPaused
    : (root.nativeMode ? (root.nativeVideo ? root.nativeVideo.paused : true)
      : player.playbackState !== MediaPlayer.PlayingState)

  // ---- page routing ----
  function pageComponent() {
    if (root.mode === "setup" || root.currentPage === "settings") return settingsPageComponent
    if (root.currentPage === "search") return searchPageComponent
    if (root.currentPage === "library") return libraryPageComponent
    if (root.currentPage === "detail") return detailPageComponent
    return homePageComponent
  }

  function pageTitle() {
    if (root.mode === "setup") return "Set up Omarchy Plex"
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
    onTriggered: { root.escapeCloseArmed = false; if (root.statusText === "Press Esc again to close") root.setStatus("", false) }
  }

  function armEscapeClose() {
    root.escapeCloseArmed = true
    // Nothing else on screen announces the arm, so the banner is what makes
    // the second Esc a decision rather than a guess.
    root.setStatus("Press Esc again to close", false)
    escapeCloseTimer.restart()
  }

  function disarmEscapeClose() {
    escapeCloseTimer.stop()
    root.escapeCloseArmed = false
    if (root.statusText === "Press Esc again to close") root.setStatus("", false)
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
  readonly property var minibarActions: ["rewind", "play", "forward", "stop", "seek", "mute", "pip", "expand"]

  function activateMinibar(action) {
    var a = String(action || "")
    if (a === "rewind") { root.nudgeSeek(-10); return }
    if (a === "play") { root.togglePause(); return }
    if (a === "forward") { root.nudgeSeek(10); return }
    if (a === "stop") { root.stop(); return }
    if (a === "mute") { root.toggleMute(); return }
    if (a === "pip") { if (root.pipAvailable) root.toggleSurface(); return }
    if (a === "expand") { root.enterTheater(); return }
  }

  // Header actions, left to right, only the ones currently on screen.
  readonly property var headerActions: root.navStack.length > 0 ? ["back"] : []

  function activateHeader(action) {
    if (String(action || "") === "back") root.goBack()
  }

  function cycleRegion(dir) {
    var order = ["search", "page", "sidebar"]
    // The minibar and header join the cycle so every visible control is
    // keyboard-discoverable; the minibar only while it is on screen.
    if (root.minibarVisible) order.push("minibar")
    if (root.headerActions.length > 0) order.push("header")
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
    if (region === "header") {
      var acts = root.headerActions
      root.setPanelCursor("header",
        acts.indexOf(root.cursorAction) >= 0 ? root.cursorAction : acts[0])
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
    if (root.cursorRegion === "header") {
      // One row along the top: down leaves it, h/l walk what is visible.
      if (dy > 0) { root.enterRegion("page"); return }
      if (dx === 0) return
      var hacts = root.headerActions
      var hat = hacts.indexOf(root.cursorAction)
      hat = hat < 0 ? 0 : ((hat + dx) % hacts.length + hacts.length) % hacts.length
      root.setPanelCursor("header", hacts[hat])
      return
    }
    if (root.cursorRegion === "minibar") {
      // The bar is one row at the bottom of the window: up leaves it, h/l walk
      // its actions — except on the seek slot, where horizontal IS the action:
      // a highlightable but inert slider would break "mouse never required".
      // j steps off the slider instead, down having nowhere else to go.
      if (root.cursorAction === "seek" && dx !== 0) { root.nudgeSeek(dx * 10); return }
      if (root.cursorAction === "seek" && dy > 0) {
        root.setPanelCursor("minibar", "mute")
        return
      }
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
    if (root.cursorRegion === "header") { root.activateHeader(root.cursorAction); return }
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
    // Every other transport action has a key; this one is Stop's.
    if (!ctrl && !alt && key === Qt.Key_X) {
      root.stop()
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
    if (root.windowed && !ctrl && !alt && key === Qt.Key_Q && root.qualityPickerAvailable) {
      root.toggleTrackPopup("quality")
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
    // Same standing as Space: mute must not require re-entering theater.
    // A focused text field never lets a bare M reach this line.
    if (root.mode === "playing" && !ctrl && !alt && key === Qt.Key_M) {
      root.toggleMute()
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
    // A moved surface is a NEW surface; the player must be rebuilt on it. This
    // one hook covers the n-cycle, the cross-monitor drag drop, and any late
    // correction of the initial output.
    onScreenChanged: root.bouncePipPlayer()
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    onWidthChanged: root.clampMargins()
    onHeightChanged: root.clampMargins()
    WlrLayershell.namespace: "omarchy-plex"
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
        Item {
          id: pipSlot
          anchors.fill: parent

          Loader {
            id: pipNativeLoader
            anchors.fill: parent
            asynchronous: false
            active: root.nativeMode && root.mode === "playing" && !root.windowed
              && !root.pipPlayerBounce
            source: "NativeVideoHost.qml"
            onLoaded: root.armNativePlayback()
          }
        }

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
            root.pipDragging = true
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

          // Scroll anywhere over the picture is volume. This is the PiP's
          // whole pointer answer to the theater's popup slider, which cannot
          // live on this surface: the input mask stops at the card (see
          // `mask` above), so a popup overhanging it would be visible but
          // mouse-dead. The readout chip below the strip says the number.
          // On the drag MouseArea rather than a WheelHandler on the card —
          // the same proven wheel path as the theater's video surface.
          onWheel: function(wheel) {
            root.pokeTheaterControls()
            root.nudgeVolumeWheel(wheel.angleDelta.y > 0)
          }
          // A high-rate mouse delivers position events far faster than the
          // display swaps frames, and every margin write re-lays-out the card
          // AND recomputes the input-region mask — a compositor round trip.
          // Doing that per event is the drag stutter, so the handler only
          // stashes and the FrameAnimation below applies the latest position
          // exactly once per rendered frame.
          property real targetX: 0
          property real targetY: 0
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var p = mapToItem(null, mouse.x, mouse.y)
            pipDrag.targetX = p.x
            pipDrag.targetY = p.y
            pipDrag.moved = true
          }

          FrameAnimation {
            running: pipDrag.pressed && pipDrag.moved
            onTriggered: {
              root.marginRight = pipDrag.pressRight - (pipDrag.targetX - pipDrag.pressX)
              root.marginBottom = pipDrag.pressBottom - (pipDrag.targetY - pipDrag.pressY)
              root.clampMargins()
              root.updatePipDropPreview(pipDrag.targetX, pipDrag.targetY,
                pipDrag.grabX, pipDrag.grabY)
            }
          }
          // A bare click on the picture is a focus grab, not a move: the
          // handoff (and its state write) belongs to gestures that actually
          // moved. handlePipDrop falls back to a plain snap when the drop
          // landed on the screen it started from.
          onReleased: function(mouse) {
            root.pipDragging = false
            root.pipDropScreen = null
            if (!pipDrag.moved) return
            var p = mapToItem(null, mouse.x, mouse.y)
            root.handlePipDrop(p.x, p.y, pipDrag.grabX, pipDrag.grabY)
          }
        }

        // ---------- resize grips ----------
        //
        // The card is anchored by its RIGHT and BOTTOM edges: x is computed as
        // `surface width - card width - marginRight`, so marginRight pins the
        // right edge and the LEFT edge is whatever the width leaves. That
        // asymmetry is the whole of the margin math below.
        //
        // TOP-LEFT grip sits on the free edge. Growing the width moves the left
        // edge out on its own and marginRight never has to change — which is
        // why the original grip is three lines and touches no margin at all.
        //
        // TOP-RIGHT grip sits on the ANCHORED edge, so the naive mirror is
        // wrong: growing the width there would extend the card leftwards and
        // the grip would slide out from under the pointer in the opposite
        // direction to the drag. For the right edge to follow the pointer,
        // marginRight has to shrink by exactly what the width gained:
        //
        //   right edge  = surfaceW - marginRight          (moves right by d)
        //   marginRight = pressRight - d
        //   width       = startW + d
        //   left edge   = rightEdge - width
        //               = (surfaceW - pressRight + d) - (startW + d)
        //               = surfaceW - pressRight - startW  → CONSTANT
        //
        // So the left edge stays nailed down and the right edge tracks the
        // pointer 1:1 — the exact mirror of the left grip's feel. The margin is
        // derived from the width the clamp actually GRANTED rather than from
        // the raw pointer delta, because otherwise a card already at its
        // minimum or maximum width would keep sliding sideways while the width
        // sat pinned.
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
            // No save here: a write per mouse event is a shell process per
            // frame. The release below persists the settled width once.
            // Cap at the surface, not a constant — any fixed pixel ceiling that
            // suits a laptop reads as "not very big" on a 4K monitor.
            root.videoWidth = Math.max(280, Math.min(
              (window.screen ? window.screen.width : 3800) - Style.space(28),
              startW + (sx - gx)))
          }
          onReleased: root.saveWidth()
        }

        MouseArea {
          id: resizeGripRight
          anchors.right: parent.right
          anchors.top: parent.top
          width: Style.space(28)
          height: Style.space(28)
          z: 100
          // The other diagonal: this corner grows down-right, the left one
          // grows down-left.
          cursorShape: Qt.SizeBDiagCursor
          property real sx: 0
          property int startW: 0
          property int pressRight: 0
          onPressed: function(mouse) {
            sx = mapToItem(null, mouse.x, mouse.y).x
            startW = root.videoWidth
            pressRight = root.marginRight
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            var gx = mapToItem(null, mouse.x, mouse.y).x
            // Dragging RIGHT (gx > sx) grows the card. Same clamp as the left
            // grip; no save per frame, for the same reason.
            var next = Math.max(280, Math.min(
              (window.screen ? window.screen.width : 3800) - Style.space(28),
              startW + (gx - sx)))
            root.videoWidth = next
            // Give back exactly the width that was granted, so the right edge
            // lands under the pointer and the left edge does not move. Assigning
            // videoWidth above already ran clampMargins against the OLD margin;
            // this write and the clamp after it settle the pair together.
            root.marginRight = pressRight - (next - startW)
            root.clampMargins()
          }
          onReleased: root.saveWidth()
        }

        // ---------- the whisper of controls ----------
        // Everything the PiP offers: the deck cluster, scrub, volume, and the
        // way back to the real window — the theater's deck-left-of-timeline
        // order, minus the pickers. Fades like the theater strip and on the
        // same timer, so a key press wakes it even with the pointer parked
        // elsewhere.
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

          Row {
            id: pipDeck
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            TransportButton {
              glyphText: "󰒮"
              tooltipText: "Back 10s · ←"
              foreground: root.foreground
              hasCursor: root.cursorOn("pip", "rewind")
              onClicked: root.nudgeSeek(-10)
              onHovered: function(on) { if (on) root.setPanelCursor("pip", "rewind") }
            }

            TransportButton {
              glyphText: root.isPaused ? "󰐊" : "󰏤"
              glyphSize: Style.font.iconLarge
              tooltipText: root.isPaused ? "Play · Space" : "Pause · Space"
              foreground: root.foreground
              hasCursor: root.cursorOn("pip", "play")
              onClicked: root.togglePause()
              onHovered: function(on) { if (on) root.setPanelCursor("pip", "play") }
            }

            TransportButton {
              glyphText: "󰒭"
              tooltipText: "Forward 10s · →"
              foreground: root.foreground
              hasCursor: root.cursorOn("pip", "forward")
              onClicked: root.nudgeSeek(10)
              onHovered: function(on) { if (on) root.setPanelCursor("pip", "forward") }
            }
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
            // Condition, not `visible`: while the strip is faded out the
            // whole chain reads visible === false, and a width keyed on it
            // hands this button's pixels to the scrubber — whose knob then
            // animates a false "seek" at every fade edge (same note as
            // theaterTitle in TheaterView.qml).
            width: Quickshell.screens.length > 1 ? implicitWidth : 0
            anchors.right: pipPop.left
            anchors.rightMargin: Quickshell.screens.length > 1 ? Style.space(2) : 0
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f037a}"
            tooltipText: "Move to the next monitor · N"
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("pip", "screen")
            onClicked: root.cyclePipScreen(1)
            onHovered: function(on) { if (on) root.setPanelCursor("pip", "screen") }
          }

          // Volume on the strip: mute on click, wheel to adjust, the current
          // percentage in the tooltip. No popup slider here — see the input-
          // mask note on the card's WheelHandler — and none needed: the wheel
          // works over the whole picture, and the real slider is one Esc away.
          TransportButton {
            id: pipMute
            visible: !root.mpvMode
            width: root.mpvMode ? 0 : controlSize
            anchors.right: pipScreenButton.left
            anchors.rightMargin: root.mpvMode ? 0 : Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            glyphText: root.audioMuted ? "󰖁" : "󰕾"
            tooltipText: (root.audioMuted ? "Unmute · M" : "Mute · M")
              + " · scroll for volume — " + root.volumePct + "%"
            foreground: root.audioMuted ? root.urgent : root.foreground
            hasCursor: root.cursorOn("pip", "mute")
            onClicked: root.toggleMute()
            onHovered: function(on) { if (on) root.setPanelCursor("pip", "mute") }

            WheelHandler {
              // Explicit, as in the Spotify plugin: the default acceptedDevices
              // is Mouse alone, which drops touchpad scrolling entirely.
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) { root.nudgeVolumeWheel(event.angleDelta.y > 0) }
            }
          }

          CursorSurface {
            id: pipSeekCursor
            anchors.left: pipDeck.right
            anchors.leftMargin: Style.space(6)
            anchors.right: pipMute.left
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

        // Wheel feedback. The theater flashes its popup readout on every
        // volume step; this chip is the PiP's equivalent, riding the same
        // volumeAdjusting flag so it appears and fades on the same 1500ms
        // clock with zero extra state. Opaque like pipCard, and for the same
        // reason: translucency over moving video reads as a rendering fault.
        BorderSurface {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(8)
          width: volumeChipText.implicitWidth + Style.space(16)
          height: Style.space(26)
          radius: Style.cornerRadius
          color: root.background
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          opacity: root.volumeAdjusting ? 1 : 0
          visible: opacity > 0.01
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Text {
            id: volumeChipText
            anchors.centerIn: parent
            text: (root.audioMuted ? "muted · " : "") + root.volumePct + "%"
            // Same accent-past-100 signal as the theater popup's readout.
            color: root.volumePct > 100 ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
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
  // ---- cross-monitor drop preview ----
  // One click-through overlay per OTHER output, mapped only while a drag's
  // pointer is actually over that output. It draws the card outline at the
  // exact clamped landing spot, so "will it drop where my mouse is?" is not a
  // leap of faith. An empty input
  // Region makes the whole surface transparent to the pointer, so the drag's
  // implicit grab on the origin surface is never disturbed.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: ghostWindow
      required property var modelData
      screen: modelData
      visible: root.pipDragging && root.pipDropScreen !== null
        && root.sameScreen(root.pipDropScreen, modelData)
      anchors { top: true; left: true; right: true; bottom: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-plex-ghost"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      Rectangle {
        x: Math.round(root.pipGhostX)
        y: Math.round(root.pipGhostY)
        width: root.videoWidth
        height: root.videoHeight
        radius: Style.cornerRadius
        color: Style.hoverFillFor(root.foreground, root.accent)
        border.color: root.accent
        border.width: Style.space(2)

        Text {
          anchors.centerIn: parent
          text: "󰐃"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }
      }
    }
  }

  FloatingWindow {
    id: appWindow
    visible: root.opened && root.windowed && !root.sessionLocked
    title: root.mode === "playing" && root.currentTitle !== ""
      ? root.currentTitle + " — Omarchy Plex" : "Omarchy Plex"
    color: root.background
    implicitWidth: 960
    implicitHeight: 600
    minimumSize: Qt.size(480, 360)
    onVisibleChanged: if (visible) root.focusPrimary()
    // A compositor-initiated close (Super+Q, killactive) bypasses root.close()
    // entirely: playback would keep running with no surface and `opened` would
    // desync from reality. Our OWN hides flip
    // opened/windowed/sessionLocked before visibility changes, so those cases
    // fall through the guards and only an external close lands here.
    onClosed: {
      if (root.opened && root.windowed && !root.sessionLocked) root.close()
    }

    FocusScope {
      id: content
      anchors.fill: parent
      focus: true

      // Below this the sidebar drops to an icon rail. Only the real window is
      // width-responsive — the PiP has no sidebar to collapse — so this is
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
      Item {
        id: theaterSlot
        anchors.fill: parent

        // This surface's OWN native player — never reparented (the crash
        // note at the native block is the whole story). Created only while
        // this surface is showing native playback; destroying it on the way
        // out is MpvQt's supported teardown path.
        Loader {
          id: theaterNativeLoader
          anchors.fill: parent
          asynchronous: false
          active: root.nativeMode && root.mode === "playing" && root.windowed
          // Alive while browsing (playback continues behind the minibar),
          // painted only in theater — without this the film renders full-bleed
          // UNDER the browse UI.
          visible: root.inTheater
          source: "NativeVideoHost.qml"
          onLoaded: root.armNativePlayback()
        }
      }

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
                text: "Omarchy Plex"
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
                - (backButton.visible ? backButton.width + parent.spacing : 0))
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
            // cycling dies inside the field unless Tab is forwarded by hand:
            // Tab does nothing, and the next letter types into the query.
            Keys.onTabPressed: function(event) { event.accepted = true; root.cycleRegion(1) }
            Keys.onBacktabPressed: function(event) { event.accepted = true; root.cycleRegion(-1) }
            // Focus and cursor region must never disagree: open() focuses this
            // field directly, and if the region still says "page", the first Tab
            // walks page->sidebar and the second wraps straight back into the
            // field, so the next letter is typed instead of navigating.
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
        // style: artwork well, title + clock, the deck cluster, thin seek
        // slider, volume, and the way back into theater — the same deck-left-
        // of-timeline order as the theater strip and the PiP. Only on screen
        // while a session is live and the video is not.
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
              id: minibarArtImage
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
              // Keyed on load state, not just an empty path: a 404'd fetch
              // leaves neither image nor glyph, just the bare well.
              visible: minibarArtImage.status !== Image.Ready
              text: "󰎁"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            anchors.left: minibarArt.right
            anchors.leftMargin: Style.space(9)
            anchors.right: minibarTransport.left
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
            anchors.right: minibarMute.left
            anchors.rightMargin: visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            hasCursor: root.cursorOn("minibar", "seek")
            foreground: root.foreground
            accent: root.accent
            // A scrubber gets no hover box: hover still claims the panel cursor
            // and the keyboard "seek" action stays reachable, but a rectangle
            // snapping up around the timeline reads as a rendering defect
            // rather than a highlight. The knob below carries the keyboard
            // indication instead.
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

          // Deck cluster left of the scrubber, matching theater and the PiP.
          Row {
            id: minibarTransport
            anchors.right: minibarSeek.left
            anchors.rightMargin: Style.space(8)
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

            // Stop ends the session and Forward gets clicked in bursts; the
            // wider gap keeps a drifted triple-tap off it. Same spacing rule
            // as the theater deck.
            Item { width: Style.space(6); height: 1 }

            TransportButton {
              glyphText: "󰓛"
              tooltipText: "Stop"
              foreground: root.urgent
              hasCursor: root.cursorOn("minibar", "stop")
              onClicked: root.stop()
              onHovered: function(on) { if (on) root.setPanelCursor("minibar", "stop") }
            }
          }

          // Volume: mute on click, wheel to adjust, percentage in the tooltip.
          // Same treatment as the PiP strip's button — no popup slider on the
          // bar; the full slider lives in theater.
          TransportButton {
            id: minibarMute
            anchors.right: minibarPip.left
            anchors.rightMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            glyphText: root.audioMuted ? "󰖁" : "󰕾"
            // Muted rather than hidden under mpv, matching the PiP button one
            // over: the keyboard walk stays sound and the tooltip says why.
            // Volume still travels over mpv's IPC; only mute is mpv's own.
            opacity: root.mpvMode ? 0.4 : 1
            tooltipText: root.mpvMode
              ? "Scroll for volume — mpv owns its own mute"
              : (root.audioMuted ? "Unmute · M" : "Mute · M")
                + " · scroll for volume — " + root.volumePct + "%"
            foreground: root.audioMuted && !root.mpvMode ? root.urgent : root.foreground
            hasCursor: root.cursorOn("minibar", "mute")
            onClicked: root.toggleMute()
            onHovered: function(on) { if (on) root.setPanelCursor("minibar", "mute") }

            WheelHandler {
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) { root.nudgeVolumeWheel(event.angleDelta.y > 0) }
            }
          }

          Button {
            id: minibarPip
            anchors.right: minibarExpand.left
            anchors.rightMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f0403}"
            // Muted rather than hidden when unavailable, matching the header
            // button: the tooltip gets to say why.
            opacity: root.pipAvailable ? 1 : 0.4
            tooltipText: root.pipAvailable
              ? "Picture-in-picture · P"
              : (root.mpvMode ? "mpv has the picture in its own window" : "Picture-in-picture · play something first")
            foreground: root.foreground
            focusable: false
            hasCursor: root.cursorOn("minibar", "pip")
            onClicked: if (root.pipAvailable) root.toggleSurface()
            onHovered: function(on) { if (on) root.setPanelCursor("minibar", "pip") }
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
      // startSystemResize sits alongside startSystemMove on FloatingWindow
      // (Qt::Edges parameter), so the four edges and four corners each get a
      // grab band. Declared last, and z-raised, so they win over the
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
  //
  // Only the QtMultimedia sink lives in here. The native players are
  // per-surface (see theaterSlot/pipSlot) because a reparented FBO's render
  // context dies with the window swap and takes the shell down with it, so the
  // native engine never rides this reparent.
  Item {
    id: videoLayer
    parent: root.windowed ? theaterSlot : pipSlot
    anchors.fill: parent
    // In the PiP the picture is the entire point, so it is never hidden there.
    visible: !root.windowed || root.inTheater

    VideoOutput {
      id: videoOut
      anchors.fill: parent
      // Hidden, not destroyed, when libmpv has the picture: player.videoOutput
      // is a sink pointer QtMultimedia holds for the life of the session, and
      // this is the fallback the panel drops back to if the module goes away
      // between runs.
      visible: root.backend !== "mpv" && !root.nativeMode
      fillMode: VideoOutput.PreserveAspectFit
    }
  }
}
