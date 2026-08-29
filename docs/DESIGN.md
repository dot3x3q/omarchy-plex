# Plex Mini — Design Spec (the fork's north star)

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

## Keyboard model (adopted from Spotify app)

- Arrows + `h/j/k/l` move the single cursor; Tab cycles regions; Home/End.
- `/` focus search · Enter activate/drill · Esc layered: popup → search →
  back-stack → arm-close → close (armed close button goes urgent, 1500ms).
- Theater: Space pause · ←/→ seek 10s · Shift+←/→ 30s · ↑/↓ volume ±5 (0–200%,
  the >100 zone rides PipeWire per-stream boost on the internal backend, native
  on mpv; settled 2026-08-29 after "seriously quiet movies") · m mute · p PiP ·
  f fullscreen (compositor) · Esc to browse (playback continues).
- Single-letter shortcuts gate on `typingInField`.

## Implementation phases (UI first — libmpv comes after)

1. **Shell skeleton + bug kills**: kit imports, chromeless window, sidebar +
   page loader + header/banner/search scaffold, panel-cursor model,
   FastScrollHandler, restyled rows (instant hover). Setup form → settings
   page. Floaty mode temporarily unchanged.
2. **Browse**: Plex API layer (sections, onDeck, recentlyAdded, children,
   search), poster grid + shelves, detail pages with dimmed backdrops,
   season/episode drill-down.
3. **Theater + minibar**: overlay controls with auto-hide, minibar with
   ack-pattern seek slider, Esc-to-browse-while-playing.
4. **PiP floaty rebuild** (video-only layer surface, fixed drag) + **bar
   widget** now-playing marquee.
5. Polish: tooltips+shortcut coverage, empty/loading copy pass, track/subtitle
   pickers (may slip to post-libmpv).

Then: libmpv render-in-window (existing roadmap item), replacing QtMultimedia.

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
- Hyprland rules still match `title: Plex Mini` (class is shared
  `org.quickshell`) — keep the title stable in browse, retitle in theater.

## Post-launch field decisions (2026-08-29, from 3x3q's live testing)

- Volume is one number, `volumePct` 0–200, persisted; slider lives in the
  theater strip with a tick at 100. Qt caps the player at 100%, so the boost
  zone sets PipeWire per-stream volume on the quickshell output streams and
  restores 1.0 on every exit path.
- The theater strip is ONE row (space(46)): title · time · flexible seek ·
  time · transport · volume. Responsive drops: title, then volume slider.
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
- Queued next: vertical volume popup on mute hover (magnetic detents at
  50/100/150/200, replaces the inline strip slider), stream-quality picker
  (Original/direct + transcode tiers, joins the track popups), PiP resize grip
  top-right in addition to top-left.
