# omarchy-plex — Design Spec (the fork's north star)

Settled with 3x3q on 2026-08-28. This is the authoritative look-and-feel document
for the fork's divergence from upstream's "nano-Plex". When code and this doc
disagree, one of them is wrong — fix whichever it is.

**One-line vision:** the Omarchy Spotify app, reshaped for Plex video. A real
window in the tiling tree, sidebar + browser like Plex desktop, launcher-grade
keyboard UX, built entirely on the shared Omarchy shell kit so it inherits the
theme system for free.

Reference implementation: `~/.config/omarchy/plugins/quickshell.spotify/` —
when unsure how something should look or feel, open that app and steal the
pattern. It is ~95% composition of `/usr/share/omarchy/shell/{Commons,Ui}/`.

## Settled decisions (2026-08-28)

| Question | Decision |
|---|---|
| Browse presentation | **Hybrid**: poster grids for movie/show libraries and shelves; rows for episodes, search results, Continue Watching |
| Playback layout | **Theater + minibar**: video fills the window, overlay controls auto-hide; Esc drops to browse while playback continues, with a Spotify-style bottom now-playing bar (thumb, title, progress, transport); click bar → back to theater |
| Floaty layer-shell mode | **Pure PiP**: video + whisper-thin controls only. All browse/search/setup lives in the real window. `⛶` pops back to windowed |
| Sequencing | **UI revamp first** on QtMultimedia; libmpv slots into the settled layout afterward |
| Content scope | **Movies + TV only** — filter `/library/sections` to `movie` and `show` types. Music stays the Spotify app's lane |
| Poster click | **Detail pages for both** movies and shows: hero (backdrop art, synopsis, year/rating/duration) + Play/Resume; shows list seasons/episodes below. Enter on a movie hero plays |
| Keyboard | **Launcher-grade**: type-to-search on open, arrows AND hjkl, `/` focuses search, Enter drills in, layered Esc, Space/f/m in theater. Mouse fully equivalent, never required |
| Visual tone | **Backdrops, dimmed**: detail heroes get the item's wide art heavily scrimmed under theme-colored text. Browse stays flat theme surfaces + posters |
| Bar widget | **Icon + now-playing text**: idle = icon; playing = title next to it (render-thread marquee if long); click toggles the window |
| Home page | **Continue Watching + Recently Added**: On Deck rows first, then a Recently Added poster shelf per library. Opens into type-to-search |
| Search scope | **Global always**: one box, whole server, `/` from anywhere |

## The three launch bugs (all confirmed in code, all die in phase 1)

1. **Title bar** (`PlexPanel.qml` 34px header row): nuked. The Spotify app's
   `FloatingWindow` draws zero chrome — Hyprland owns frame, drag, resize.
   Header functions rehome: close → Esc/compositor, pin toggle → PiP button in
   the now-playing bar, title → window `title:` property only (for Hyprland
   rules), status → status banner between header and search (Spotify pattern).
2. **Floaty drag oscillation** — DEAD in wave 4. The handler read an item-local
   `mouse.x` while writing `margins`, but `zwlr_layer_surface_v1.set_margin` is
   double-buffered: the compositor applies it on its own schedule and never
   tells the client. So the coordinate frame being measured was still being
   moved by the handler's own un-applied writes, the pending delta was counted
   twice, and the panel orbited the cursor. There is no API fix —
   wlr-layer-shell has no move request, Quickshell's `startSystemMove` exists
   only on `FloatingWindow`, `PanelWindow` has no position readback, and nothing
   signals "margin applied".
   **The fix is to stop moving the surface.** The PiP's `PanelWindow` is anchored
   to all four edges, transparent, and `mask`ed to the card, and the card is an
   ordinary Item dragged by `x`/`y` in scene coordinates. Item coordinates
   resolve inside Qt's scene graph, so the position set is the position on the
   next frame — nothing to oscillate against. `marginRight`/`marginBottom` keep
   their names and their persisted schema but now place the card. Release does
   edge magnetism (`Style.space(40)` band → `Style.space(14)` inset), so corners
   are deterministic without giving up free placement. Same idiom as the shell's
   bar drag ghost (`plugins/bar/Bar.qml`:1170-1190).
3. **Laggy hover** (`Behavior on color` 100ms on rows): deleted. Spotify's
   `MediaRow` has **zero** animation on rows — fill snaps instantly. Their
   only animations: button color 120ms, cursor surfaces 60ms, sliders 140ms
   OutCubic (disabled while dragging). Everything else is deliberately instant.

## Design language — build on the kit, don't imitate it

Full extraction lives in the 2026-08-28 design-agent report (condensed here);
the living reference is the Spotify plugin source.

- `import qs.Commons` + `import qs.Ui`. Use `Color`, `Style`, `Border`,
  `BorderSurface`, `Button`, `TextField`, `PanelSlider`, `PanelSeparator`,
  `PanelToolTip`, `CursorSurface`, `FastScrollHandler` (copy from the Spotify
  plugin — it's plugin-local, not kit).
- **Never write a hex color, font family, or bare pixel.** Palette roles
  (`Color.foreground/background/accent/muted/urgent`), `Style.font.*` scale,
  `Style.space(n)` for every dimension. Corner radius = `Style.cornerRadius`
  (mirrors Hyprland's `decoration:rounding`).
- **Card recipe** (sidebar, footer, banners, artwork wells):
  `BorderSurface { radius: Style.cornerRadius; color: Style.normalFillFor(fg, accent); borderSpec: Border.controlSpec("normal", fg, accent) }`.
  Surfaces are foreground-at-alpha over the window background: idle 0.04,
  hover 0.08, selected 0.18, pressed 0.22 — via `Style.*FillFor()` helpers only.
- **Panel-cursor model**: ONE highlight on screen, shared by mouse and
  keyboard. Controls read `hasCursor: root.cursorOn(region, action)` and write
  `onHovered: setPanelCursor(...)`. Never bind visuals to `containsMouse`.
- **FastScrollHandler in every scrollable list**: cancels flick physics,
  drives `contentY` directly at 4× wheel speed. This (plus unanimated rows) is
  why their lists feel instant.
- Typography: one family (`Style.font.family`, the user's mono Nerd Font),
  two weights (regular/bold). Captions for metadata, body for titles, bold
  UPPERCASE captions for section headings. Keyboard-selected row title goes bold.
- Icons: Nerd Font MDI glyphs as `Text`, never SVG. Transport rows copy
  `TransportButton.qml`'s tight-bounding-rect optical centering.
- No spinners, no skeletons: empty state and loading state are the same muted
  centered label with *different specific sentences* ("Loading On Deck…" vs
  "Nothing in progress. Search to start something.").
- No blur/gradients/shadows in-panel — EXCEPT our settled divergence: dimmed
  backdrop art on detail heroes (and theater idle). Scrim heavily; theme text
  must stay legible on top across all themes.
- Layout stability: `height: visible ? x : 0` collapses, reserve max-state
  borders, nothing shifts on hover/selection.
- Tooltips everywhere, teaching shortcuts: `"Play · Space"` style, 400ms delay.
- Async seek/volume: copy the Spotify `PlaybackSlider` preview-until-
  acknowledged pattern (min 300ms hold, 8s timeout, contextKey clears on item
  change) so the knob never snaps back while Plex round-trips.

## Screen inventory

```
FloatingWindow (no chrome; content margin Style.space(14))
├ sidebar (BorderSurface, ~space(176-214), icon rail when narrow)
│   Home · <video libraries from /library/sections> · ─── · Settings (bottom)
├ content pane
│   header row: [back?] [title/subtitle] [refresh] [close]
│   status banner (conditional, error/info)
│   search field (global, / focuses, debounced)
│   page loader:
│     home      — On Deck rows + Recently Added poster shelf per library
│     library   — poster grid (sort: recently added / title / year)
│     detail    — dimmed-backdrop hero + Play/Resume; shows: season picker + episode rows
│     search    — row results (type chips if useful)
│     theater   — video fills pane+sidebar area, overlay controls auto-hide
│     settings  — server/token setup (current setup form, restyled), backend pick
└ now-playing minibar (BorderSurface, visible when playing && !theater)
    [thumb] [title · progress caption] [⏮ ⏯ ⏭] [seek slider] [time] [PiP] [⛶ theater]

PanelWindow (PiP mode): video + hover controls (seek strip, ⏯, ⛶ to window)
Bar widget: icon; + marquee title while playing; click toggles window
```

Navigation: Loader + `pageComponent()` function, sidebar Buttons with
`selected:` state, `navigationStack` for back (Alt+Left / layered Esc), LRU
scroll-position memory per page key. No page transitions.

## Keyboard model (adopted from Spotify app; reconciled against `PlexPanel.qml`'s
dispatchers 2026-08-29 — `handleKey`/`handlePlayingKey`/`handlePipKey`/
`handleTrackPopupKey`)

- Arrows + `h/j/k/l` move the single cursor; Tab/Shift+Tab cycles regions
  (search → page → sidebar → minibar when visible). **Home/End are NOT
  implemented for browse cursor movement** — only inside the track popup
  (below). Drop "Home/End" from the browse story until/unless a page grows
  that behavior.
- `/` focus search · Enter activate/drill · Esc layered: track popup close →
  clear non-empty search → leave search field → exit theater to browse →
  back-stack → arm-close → close (armed close button goes urgent, 1500ms).
- Theater/PiP (shared `handlePlayingKey`): Space or Enter pause/resume ·
  ←/→ seek 10s · Shift+←/→ 30s · ↑/↓ volume ±5 (0–200%, the >100 zone rides
  PipeWire per-stream boost on the internal backend, native on mpv; settled
  2026-08-29 after "seriously quiet movies") · m mute · p toggles PiP ·
  a/s/q open the audio / subtitle / stream-quality popup (window/theater only —
  gated on `root.windowed`, no room on the PiP strip) · Esc: PiP exits to
  window, theater exits to browse (playback continues either way).
  ↑/↓ also reveal the vertical volume popup for as long as the reading flashes;
  that is the only keyboard route to it, since there is no cursor walk along
  the strip.
  **There is no `f` fullscreen binding in code** — fullscreen is left to the
  compositor's own keybinding; drop "f fullscreen" from this list, it does
  not exist in `handlePlayingKey`.
- PiP-only, on top of the shared theater keys: `n` cycles the PiP to the next
  monitor, `Shift+n` to the previous (multi-monitor; not meaningful in
  windowed mode, where the compositor already owns monitor placement).
- Picker popup (audio / subtitle / quality — ONE widget keyed by `trackPopup`;
  `handleTrackPopupKey` intercepts before Esc's layered walk and before
  transport keys): ↑/↓ or j/k move selection · Home/End jump to first/last ·
  Enter selects · a/s/q swap between the three lists · Esc closes the popup
  only. Every other key is swallowed, so a stray Space cannot pause the film
  behind an open list.
- Single-letter shortcuts are effectively gated on text-field focus by
  ordinary Qt key delivery (a focused `TextField` consumes printable
  characters before they can reach the root dispatcher) rather than by an
  explicit `typingInField` flag anywhere in code — worth knowing if a new
  single-letter shortcut is ever added, since it needs that same implicit
  protection.

## Implementation phases (UI first — libmpv comes after)

Status as of 2026-08-29 — phases 1-4 are DONE and field-tested; phase 5 is
partially done (see below); libmpv has not started.

1. **DONE — Shell skeleton + bug kills**: kit imports, chromeless window,
   sidebar + page loader + header/banner/search scaffold, panel-cursor model,
   FastScrollHandler, restyled rows (instant hover). Setup form → settings
   page. All three launch bugs (title bar, drag oscillation, laggy hover)
   confirmed dead in code.
2. **DONE — Browse**: Plex API layer (sections, onDeck, recentlyAdded,
   children, search), poster grid + shelves, detail pages with dimmed
   backdrops, season/episode drill-down.
3. **DONE — Theater + minibar**: overlay controls with auto-hide, minibar,
   Esc-to-browse-while-playing. The strip is one row (space(46)); the
   ack-pattern preview-until-acknowledged slider behavior described above
   under "Async seek/volume" — verify against `TheaterView.qml` if precision
   matters, it was not re-checked in this doc pass.
4. **DONE — PiP floaty rebuild** (video-only layer surface, fixed drag,
   now verified 1:1 drag / corner snap / click-through / focus handoff by
   3x3q live, plus multi-monitor `n`/`Shift+n` cycling added post-launch)
   **and bar widget** now-playing marquee (render-thread XAnimator, freezes
   while paused).
5. **PARTIAL — Polish**: audio/subtitle track pickers shipped (pulled forward
   from "may slip to post-libmpv" — they landed same wave as PiP, gated to
   window/theater only), and the three queued field-decision items below
   (vertical volume popup, stream-quality picker, second PiP resize grip) all
   shipped 2026-08-29. Still open: tooltip+shortcut coverage pass,
   empty/loading copy pass.

**Not started: libmpv render-in-window**, replacing QtMultimedia — still the
next major roadmap item after this UI revamp, per `AGENTS.md`'s roadmap
section. Nothing in this repo currently does in-window libmpv rendering; the
existing `mpv` backend is the pre-existing external-process/IPC mode, not a
step toward it.

## Known risks / notes

- **Poster/backdrop URLs**: QML `Image` cannot send headers, so artwork must
  use `X-Plex-Token` as a query param on `/photo/:/transcode` URLs. This is a
  deliberate, documented exception to upstream's token-in-headers-only posture
  (same exception already exists for the internal-backend media URL). Keep
  tokens out of logs; never log image URLs.
- Backdrop-over-theme legibility: scrim hard (Spotify's watermark treatment is
  the calibration point), test across several Omarchy themes incl. light.
- `reuseItems: true` + `cache: false` on row artwork (recycled delegates must
  not hoard pixmaps); `sourceSize` capped per context.
- Hyprland rules still match `title: Omarchy Plex` (class is shared
  `org.quickshell`) — keep the title stable in browse, retitle in theater.

## Post-launch field decisions (2026-08-29, from 3x3q's live testing)

- Volume is one number, `volumePct` 0–200, persisted. Qt caps the player at
  100%, so the boost zone sets PipeWire per-stream volume on the quickshell
  output streams and restores 1.0 on every exit path.
- The theater strip is ONE row (space(46)): title · time · flexible seek ·
  time · transport. The only responsive drop left is the title — the volume
  slider used to be the second one and no longer sits in the row at all.
- Scrubbers draw no hover box (CursorSurface fill transparent) — the knob is
  the affordance; keyboard cursor shows as an accent knob.
- Drag-anywhere on bare surface moves the real window via startSystemMove;
  8px edge bands resize via startSystemResize. Lists keep their drags.
- `p` toggles PiP everywhere; PiP size cap is the surface width, not 900px.
- PiP verified by 3x3q: drag 1:1, corner snap, click-through desktop, focus
  handoff — all confirmed perfect.
- Browse-alongside-PiP: considered and REJECTED (3x3q, 2026-08-29) — "I really
  like having everything in the same window." The PiP stays video-only; getting
  back to browse means popping back to the real window. Do not resurrect.
### The queued batch — all three SHIPPED 2026-08-29

- **Vertical volume popup.** Replaces the inline strip slider. Hangs above the
  mute button as a child of it (so it tracks the right-anchored Row through
  every reflow without stale `mapToItem` arithmetic), opaque body like
  `pipCard` because PanelSlider's knob-ring idiom needs a solid ground.
  `PanelSlider` is horizontal-only and rotating it would leave hit-testing and
  tooltips on the wrong axis, so the vertical variant is built by hand in
  `TheaterView.qml` with the kit's roles copied exactly (track =
  `selectedFillFor`, fill = foreground, knob = foreground circle ringed in
  background, ticks cut in background).
  Open while the pointer is on the button OR the popup, plus a 300ms grace so
  the diagonal traverse survives; `volumeAdjusting` also shows it, which is how
  ↑/↓ reaches it (there is no cursor walk along the strip).
  **Magnetic detents** at 0/50/100/150/200, pull ±8, applied to drag and wheel
  but NOT to the keyboard's ±5 (that grid already lands on every notch, and
  snapping it would make 95 and 105 unreachable). The wheel step is **10, larger
  than the pull on purpose** — a relative step smaller than the pull can never
  escape a detent, which would turn every notch into a trap.
  Theater only: the PiP strip has no mute button to anchor to.
- **Stream-quality picker.** Third button in the strip (nf-md-quality_high,
  `\u{f07fd}`, glyph presence verified in the resolved mono Nerd Font), `q` to
  open. Rides the SAME popup as the track pickers — `trackPopup` now takes
  `"quality"`, `trackRows()` dispatches, and `activatePickerRow()` is the one
  branch point — rather than growing a second widget with its own Esc ordering.
  `qualityKbps` (0 = Original/direct play, else a kbps cap) persists in
  window.json beside `volumePct`; the value read back is checked for
  **membership in the tier list**, not clamped, because it is substituted into
  a URL.
  Tiers send a **three**-param tuple, not two — see the API note below. A
  chosen tier wins everywhere including a later codec-failure fallback; with no
  tier chosen `transcodeUrl` emits the historical 6000/60 and **omits
  videoResolution entirely**, so the automatic fallback's query is unchanged.

  | Label | maxVideoBitrate | videoQuality | videoResolution |
  |---|---|---|---|
  | Original (direct play) | — | — | — |
  | 20 Mbps · 4K | 20000 | 100 | 3840x2160 |
  | 12 Mbps · 1080p | 12000 | 90 | 1920x1080 |
  | 8 Mbps · 1080p | 8000 | 60 | 1920x1080 |
  | 4 Mbps · 720p | 4000 | 100 | 1280x720 |
  | 2 Mbps · 480p | 2000 | 60 | 720x480 |
  Applying reuses the track-restart flow: a TIER is literally
  `beginTrackRestart()` (the tier is already baked into `transcodeUrl` by two
  derived properties). **Original is the case that flow cannot express** — it
  always goes to the transcoder — so it replays the direct part URL and clears
  `triedTranscode`. That needs the part *key*, which `Api.mapStreams` does not
  return and `applyMetadata` consumes inline, so `stashStreams` now stashes
  `currentPartKey` off the same resolve response (the `metadataThumb`
  precedent). No engine block was touched.
- **Second PiP resize grip, top-right.** The card is anchored by its RIGHT and
  BOTTOM edges (`x = surfaceW - cardW - marginRight`), so the two grips are not
  symmetric. Top-LEFT sits on the free edge: growing the width moves the left
  edge on its own and no margin changes. Top-RIGHT sits on the ANCHORED edge,
  so `marginRight` must shrink by exactly what the width gained — then the left
  edge is constant and the right edge tracks the pointer 1:1. The margin is
  derived from the width the clamp actually GRANTED, or a card pinned at its
  min/max width would keep sliding sideways.
  `saveWidth()` now stages the margins too: both grips can move `marginRight`
  (the left one indirectly, via `clampMargins` when growing past the screen),
  and a resize was persisting a fresh width beside a stale margin. One posSave
  run, because Quickshell latches argv at start and drops a second launch.
