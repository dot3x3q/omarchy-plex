# Plex Mini for Omarchy — 3x3q's fork

A full Plex client for [Omarchy](https://omarchy.org)/Quickshell: a real, tileable
window with a sidebar, poster-grid browsing, detail pages, and a theater +
minibar player — plus a picture-in-picture floaty mode for when you want the
video in a corner while you do something else.

This is a fork of Joshua Warren's excellent
[omarchy-plexmini](https://github.com/joshuaswarren/omarchy-plexmini), which is
deliberately a "nano-Plex": a small bar-summoned miniplayer for Continue
Watching and quick search. That scope is a feature, not a limitation — it's
exactly what most people want from a bar widget. This fork exists because I
wanted more: a browsable library, detail pages, season/episode drill-down,
audio/subtitle track pickers, multi-monitor PiP. None of that is a knock on
the original; it's a different tool built on the same foundation, and the
foundation (the Plex API plumbing, the security posture around the token, the
transcode fallback) is still upstream's work. Go star the original.

## What it does

- **Sidebar browse**: Home (On Deck + Recently Added shelves), one entry per
  video library on your server, Settings pinned at the bottom. Movie/TV
  libraries only — Plex music and photo libraries are filtered out.
- **Poster grids and rows**: poster grids for library browsing, rows for
  episodes, search results, and Continue Watching.
- **Detail pages** for movies and shows: dimmed-backdrop hero with synopsis,
  year, rating, duration, and Play/Resume; shows list seasons and episodes
  below.
- **Global search**: one box, whole server, `/` focuses it from anywhere,
  debounced live search as you type.
- **Theater + minibar playback**: video fills the window with auto-hiding
  overlay controls; hit Esc and the session keeps playing behind a
  Spotify-style now-playing bar while you keep browsing. Click the bar to
  jump back into theater.
- **Two playback surfaces** — see below.
- **Audio and subtitle track selection**: pick a track mid-playback; the
  choice is written back to the Plex server (so it survives a transcode) and,
  on the internal backend with direct play, switched live with no restart.
- **Volume 0–200%**: Qt caps native playback volume at 100%, so above that
  the panel drives PipeWire's per-stream volume for the extra boost — same
  slider, no separate control.
- **Bar widget**: idle shows the Plex glyph; while something's playing it
  grows a scrolling now-playing title (paused freezes the marquee). Click
  toggles the window.
- **Resume, progress sync, transcode fallback** — all inherited from
  upstream: direct play resumes from Plex's stored `viewOffset`, reports
  timeline progress every 10 seconds, scrobbles at 90%, and falls back once
  to universal-transcode HLS if direct play fails.
- **Launcher-grade keyboard UX**: arrows and `hjkl` drive a single on-screen
  cursor shared with the mouse; the app is fully usable without touching the
  mouse. Full binding list below.

## Requirements

- Omarchy with Quickshell (the shell this plugin is a panel for)
- A Plex Media Server you can reach, and its `X-Plex-Token`
- `curl` (ships with Omarchy)
- Optional, only for the mpv backend: `mpv` and `socat`

## Install

Symlink (or copy) this directory into your Omarchy plugins folder:

```bash
ln -s /path/to/this/repo ~/.config/omarchy/plugins/io.github.joshuaswarren.plexmini
omarchy restart shell
```

QML/JS edits hot-reload on save once it's linked; changes to the plugin root
element or `manifest.json` need another `omarchy restart shell`.

## Setup

Open the panel (bar widget, or `omarchy-shell shell toggle
io.github.joshuaswarren.plexmini`). On first run — or whenever no server/token
is saved — it opens straight into a setup page:

1. **Server URL**, e.g. `http://192.168.1.50:32400`
2. **X-Plex-Token** — see Plex's own guide: [Finding an authentication
   token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
3. **Playback backend** — In panel (default) or mpv (see below)

Hit Enter or click Connect. This writes `~/.config/plexmini/config.json`,
chmod `0600` inside a `0700` directory, atomically (write-temp-then-rename,
symlinked destinations replaced rather than followed):

```json
{ "server": "http://192.168.1.50:32400", "token": "REDACTED", "backend": "internal" }
```

The token only ever travels in request headers for API calls. It does ride in
the media URL's query string for direct-play/transcode playback and for
poster/backdrop image requests, because QtMultimedia and QML's `Image` can't
attach custom headers — that's a documented, deliberate exception, not an
oversight. See `docs/DESIGN.md` → "Known risks" for the full accounting.

Config is currently read once at startup — editing `config.json` by hand
needs a restart of the panel (or `omarchy restart shell`) to take effect.

## The two surfaces

- **Window** (primary): a real window in Hyprland's tiling tree — tile it,
  swap it, fullscreen it like any app. This is where the sidebar, browsing,
  search, and settings live.
- **PiP** (floaty): a small always-on-top, click-through-everywhere-except-
  the-card corner overlay. Video and a hover-revealed strip only — no
  sidebar, no browse, no search. Drag it anywhere (it snaps to corners on
  release), resize from the top-left grip, and if you have more than one
  monitor, `n` / `Shift+n` walks it across them.

Pop into PiP with the pin button in the theater/minibar strip, or press `p`
anywhere a session is playing. `p` again (or Esc, or the strip's pop-back
button, or the session ending) brings you back to the window. There is no way
to browse while the PiP is up by design — 3x3q tried it live and preferred
keeping browsing and the picture-in-picture strictly separate.

## Backends

- **`internal`** (default) — video renders inside the window via
  QtMultimedia. No extra binaries needed beyond `curl`.
- **`mpv`** — playback launches in a separate mpv process, remote-controlled
  over a per-session Unix-socket IPC connection (`socat`). Useful today for
  hardware decode; a future in-window libmpv renderer (see Roadmap in
  `AGENTS.md`) is expected to make this external-process mode unnecessary.

Switch it from the Settings page any time; the change takes effect on the
next thing you play.

## Keyboard reference

The single on-screen cursor is shared by mouse and keyboard — everything
below has a mouse equivalent too.

### Everywhere (browsing)

| Key | Action |
|---|---|
| `↑` `↓` `←` `→`, `h` `j` `k` `l` | Move the cursor |
| `Tab` / `Shift+Tab` | Cycle focus region (search → page → sidebar → minibar, when visible) |
| `/` | Focus the search field |
| `Enter` | Activate the selected item / run the search |
| `Esc` | Layered: clear a non-empty search → leave the search field → exit theater back to browse → go back → arm the close button → close (a second Esc within 1.5s of arming) |
| `Alt+Left` | Back |
| `PageUp` / `PageDown` | Page the current view (list/grid-specific) |
| `r` | Refresh the current page |
| `p` | Toggle PiP (no-op if nothing is playing) |
| `Space` | Play/pause (works globally whenever something is playing, even while browsing behind the minibar) |

### Theater / PiP / minibar (while something is playing)

| Key | Action |
|---|---|
| `Space` / `Enter` | Play / pause |
| `←` / `→` | Seek 10s |
| `Shift+←` / `Shift+→` | Seek 30s |
| `↑` / `↓` | Volume ±5 (0–200%) |
| `m` | Mute |
| `p` | Toggle PiP |
| `a` | Audio track picker (window/theater only — no room for it on the PiP strip) |
| `s` | Subtitle track picker (window/theater only) |
| `n` | Move PiP to the next monitor (PiP only, multi-monitor) |
| `Shift+n` | Move PiP to the previous monitor (PiP only) |
| `Esc` | PiP: back to the window. Theater: back to browse (playback keeps running behind the minibar) |

### Track picker (audio/subtitle popup, once open)

| Key | Action |
|---|---|
| `↑` `↓`, `j` `k` | Move selection |
| `Home` / `End` | Jump to first / last track |
| `Enter` | Select the highlighted track |
| `a` | Switch to the audio list |
| `s` | Switch to the subtitle list |
| `Esc` | Close the picker |

### Search field (while typing)

| Key | Action |
|---|---|
| `Enter` | Drill into the selected result if the page cursor is active, otherwise run the search |
| `Tab` / `Shift+Tab` | Cycle region (forwarded explicitly — Qt's own text-field Tab handling is overridden here) |
| `Esc` | Clear the query if non-empty, otherwise leave the field |
| any other character | Typed into the query (letters like `h`/`j`/`k`/`l` do NOT move the cursor while the field has focus) |

## Architecture and design docs

- `docs/DESIGN.md` — the authoritative design spec: settled UI decisions,
  screen inventory, keyboard model, and the implementation-phase roadmap.
- `docs/PLEX-API.md` — every Plex endpoint this plugin calls, verified live
  against a real server, with response shapes and gotchas.
- `docs/BUILD-CONTRACT.md` — the file-ownership/interface contract used to
  parallelize the redesign build; historical now that the redesign has
  landed, kept for context on why the code is shaped the way it is.
- `AGENTS.md` — fork context, branch map, and dev-loop commands (lint, test,
  compile gate) for anyone hacking on this.

## Tests

```bash
node --test tests/*.test.mjs
```

Covers Plex response mapping (`Api.js`), config/IO safety (bounded reads,
atomic writes, no-follow), and static contract checks against the QML
(keyboard-focus mode, security-sensitive `Process` command strings).

## Removing

```bash
rm -rf ~/.config/plexmini ~/.local/state/plexmini
```

then remove the plugin symlink/directory from
`~/.config/omarchy/plugins/`.

## License

MIT — see [LICENSE](LICENSE). Same license as upstream.
