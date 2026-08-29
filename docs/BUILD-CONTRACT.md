# Build Contract — redesign branch

Interface contract for the parallel rebuild. `docs/DESIGN.md` says what we're building
and how it must look/feel; THIS file says who owns which file and what the interfaces
are. Agents: code exactly to this contract. If the contract is wrong, say so in your
report — do not silently deviate. The living visual reference is
`~/.config/omarchy/plugins/quickshell.spotify/` (MIT-licensed; adapting code with an
attribution comment is fine).

## Ground rules

- Kit first: `import qs.Commons` (Color, Style, Border) and `import qs.Ui`
  (BorderSurface, Button, TextField, PanelSlider, PanelSeparator, PanelToolTip,
  CursorSurface). Read the component sources in `/usr/share/omarchy/shell/{Commons,Ui}/`
  before using them. Never hardcode a color, font family, or bare pixel —
  `Color.*`, `Style.font.*`, `Style.space(n)`, `Style.cornerRadius`,
  `Style.*FillFor(fg, accent)`, `Border.controlSpec(state, fg, accent)`.
- Flat directory (Spotify convention). Pages/components are separate files (unlike
  Spotify's inline Components) so they can be built in parallel.
- NO list-row animations. Buttons/CursorSurfaces animate via the kit only.
- Lint gate: `qmllint -I /usr/share/omarchy/shell <file>.qml` → 0 errors.
- Test gate: `node --test tests/` stays green. `tests/panel-contract.test.mjs` pins
  security chokepoints by regex — preserve those code blocks verbatim. Only update a
  test expectation when DESIGN.md deliberately changes the behavior, and justify it
  in your report.
- Do NOT `git commit` — leave changes in the working tree; the orchestrator commits.
- The real Plex token lives in `~/.config/plexmini/config.json` (0600). You may use
  it in curl headers to verify live API shapes. NEVER print, echo, or log it.
- Comments follow upstream's style: explain why, not what.

## File ownership

| File | Owner | Wave |
|---|---|---|
| `PlexPanel.qml`, `SettingsPage.qml`, placeholder pages | Agent A | 1 |
| `Api.js`, `tests/api.test.mjs`, `docs/PLEX-API.md` | Agent B | 1 |
| `MediaRow.qml`, `PosterCard.qml`, `TransportButton.qml`, `FastScrollHandler.qml` | Agent C | 1 |
| `HomePage.qml`, `SearchPage.qml` | Agent D | 2 |
| `LibraryPage.qml` | Agent E | 2 |
| `DetailPage.qml` | Agent F | 2 |
| `TheaterView.qml`, minibar (in root) | wave 3 | 3 |
| `Model.js` | frozen — nobody touches it | — |

## Root contract (`PlexPanel.qml` exposes; pages receive `required property var panel`)

State & theme: components use `Color.*`/`Style.*` from the kit directly.

```
panel.server / panel.token          — config (read-only for pages)
panel.libraries                     — [{id, title, type: "movie"|"show"}], loaded on open
panel.mode                          — "setup" | "list" | "playing" | "error" (existing
                                      machine kept; pages are visible when mode is
                                      "list"/"error"; "playing" shows the playing view)
panel.request(path, cb)             — GET server+path with auth HEADERS via a pooled
                                      curl Process set (pool of 4 + FIFO queue; each:
                                      -s --fail --max-time 10 --max-filesize 4194304).
                                      cb(parsedJsonOrNull). Never token in URL here.
panel.imageUrl(path, w, h)          — Api.imageUrl wrapper (token in query — the ONE
                                      documented exception; never log these URLs)
panel.navigate(page, params)        — push {page, params} on navStack; page ∈
                                      "home"|"library"|"detail"|"search"|"settings"
panel.goBack()                      — pop; empty stack → home
panel.currentPage / panel.pageParams
panel.search(q)                     — existing signature kept (test-pinned); navigates
                                      to search page and fetches
panel.playItem(ratingKey, title)    — existing resolve→play flow, unchanged
panel.togglePause() / seekRel(s) / seekAbs(frac) / stop()
panel.dispTime / dispDuration / currentTitle
panel.setStatus(msg, urgent)        — status banner text (empty string clears)
panel.setPanelCursor(region, action) / panel.cursorOn(region, action)
                                    — single-highlight cursor model (Spotify
                                      Panel.qml:54-55, 632, 999). Regions:
                                      "sidebar" | "search" | "page" | "playing"
```

Keyboard: root FocusScope owns all keys (`Keys.priority: Keys.BeforeItem`).
Arrows AND h/j/k/l → if a text field has focus, only Up/Down/Enter/Esc are stolen
(launcher pattern, as today); otherwise dispatch to region. When cursor is in "page",
forward to `pageLoader.item.moveCursor(dx, dy)` / `activateCursor()`. Tab cycles
search → page → sidebar. `/` focuses search from anywhere. Esc layered: clear search
→ goBack → close (keep close() pause semantics — test-pinned). Single-letter keys gate
on text-field focus.

## Page contract (every page file)

```qml
Item {
  required property var panel
  function moveCursor(dx, dy) {}   // dy: ±1 rows, dx: ±1 columns (grids) — wrap at ends
  function activateCursor() {}     // Enter on current item
  function pageUp()/pageDown() {}  // optional
  // pages fetch their own data via panel.request in Component.onCompleted,
  // remember scroll via panel.rememberScroll(key,y)/panel.scrollFor(key) (LRU in root)
}
```

## Component contracts (Agent C)

`MediaRow.qml` — video-flavored Spotify MediaRow (their MediaRow.qml is the reference):
```qml
BorderSurface {
  required property var itemData   // see Api item shape below
  property bool selected: false    // keyboard cursor / current — 0.18 fill + bold title
  property bool cursorOn: false    // hover-or-cursor — 0.08 fill (NO animation)
  property bool browseOnActivate: false  // true → click emits openRequested
  property real artAspect: 16/9    // episode/CW thumbs are landscape; 2/3 for poster rows
  signal activated(); signal openRequested(); signal hovered(bool on)
  // anatomy: art well (BorderSurface, selectedFill, radius Style.spacing.labelGap,
  //   Image inset space(2), asynchronous, cache:false, sourceSize capped, glyph
  //   placeholder 󰦔/󰎁 when not ready) · title body / sub caption muted ·
  //   right: durationText caption muted + ▶ play Button (always visible) ·
  //   progress: when itemData.progress > 0, a 2px accent underline strip across the
  //   art well bottom, width = progress
  implicitHeight: Style.space(56)
}
```

`PosterCard.qml` — grid cell:
```qml
Item {
  required property var itemData
  property bool cursorOn: false
  signal activated(); signal hovered(bool on)   // activated → detail page
  // 2:3 poster well (same treatment as MediaRow art), title body elided below,
  // caption muted below that, progress strip on poster bottom edge.
  // cell width driven by the grid; poster fills width.
}
```

`TransportButton.qml` — port Spotify's (optical centering via TextMetrics
tightBoundingRect, `controlSize: Style.space(32)`), attribution comment at top.

`FastScrollHandler.qml` — port Spotify's verbatim + attribution comment.

## Api.js contract (Agent B — pure functions, no I/O, no QML imports)

Item shape consumed by MediaRow/PosterCard (build it here, in one place):
```js
{ ratingKey, title, sub, caption, thumbPath, artPath, type,   // type: movie|show|season|episode
  progress,        // 0..1 viewOffset/duration, or 0
  durationText,    // "1h 52m" / "52m" — add fmt here, don't touch Model.js
  year, unwatched  // leafCount-viewedLeafCount for shows, bool for movies
}
```

Functions (verify every response shape against the LIVE server before writing mappers;
document findings in `docs/PLEX-API.md` with sanitized samples — no token, no IPs
beyond the known-local server):
```
sectionsUrl(server)                          mapSections(json) → video libs only
onDeckUrl(server)                            mapItems(json)   → row items
recentlyAddedUrl(server, sectionId, size)
libraryAllUrl(server, sectionId, {sort, start, size})   — paginated
metadataUrl(server, ratingKey)               mapDetail(json)  → item + summary, rating,
                                                contentRating, genres[], artPath, Media info
childrenUrl(server, ratingKey)               mapChildren(json) → seasons or episodes
searchUrl(server, query)                     mapSearch(json)  → row items w/ type
                                                (probe /hubs/search vs /search — pick the
                                                 better-structured one, note why)
imageUrl(server, token, path, w, h)          → /photo/:/transcode?width=&height=&minSize=1
                                                &upscale=1&url=<enc>&X-Plex-Token=
```
Plus `tests/api.test.mjs` (node:test) against captured-and-sanitized fixtures.

## Wave-1 root layout (Agent A) — DESIGN.md screen inventory, phase 1 scope

FloatingWindow (chromeless — the 34px header row DIES) → content Item margins
`Style.space(14)`:
sidebar (BorderSurface; brand row "Plex Mini" + 󰚺; Home button; library buttons from
panel.libraries; PanelSeparator; Settings pinned bottom; icon-rail collapse below
`Style.space(760)` width) · content pane (header row: back?/title/subtitle + refresh +
close · status banner (collapses to 0) · search TextField (global, `/`, debounce kept)
· page Loader) · playing view for wave 1 = existing video output + restyled minimal
transport row (theater is wave 3; do not build the minibar yet, `panel.mode ===
"playing"` simply swaps the content pane for the playing view as today).
Floaty PanelWindow path: UNTOUCHED this wave (grep-pinned by tests; PiP rebuild is
wave 4). Placeholder `HomePage.qml`/`SearchPage.qml`/`LibraryPage.qml`/`DetailPage.qml`
(valid page-contract files showing a muted "…" label) so the Loader and lint pass —
wave 2 overwrites them. `SettingsPage.qml` is REAL in wave 1: the current setup form
restyled with kit TextFields/Buttons + backend picker, same save flow (test-pinned IO).

Window title stays "Plex Mini" (Hyprland rules match on it); playing retitles
"<media> — Plex Mini" as today.
