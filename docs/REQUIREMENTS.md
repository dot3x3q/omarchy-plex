# Plex Mini — Requirements

Status: **implemented** (v0.1.0, live-verified on Omarchy 4 / Quattro)
Target: Omarchy 4 / Quattro shell (Quickshell plugin API)
Plugin ID: `io.github.joshuaswarren.plexmini`
Kind: `panel` + `bar-widget`

## 1. Problem

Watching something from your own Plex library while working means a full Plex client fighting for screen space, or casting to a shim and losing all controls to a phone. Nothing gives you "pick from Continue Watching, play it small, keep working" in one surface.

## 2. Goals

- G1: Continue Watching on open; full library search (`/search`) in the same list.
- G2: Default playback renders inside the resizable panel via QtMultimedia, ytmini-style. Optional mpv mode provides a separate dGPU-backed window.
- G3: Full keyboard control and live type-to-search; Space pauses, Esc pauses then hides, Left/Right seek, and the top-left grip resizes.
- G4: Watch progress reported via `//:/timeline` every 10s; scrobbled at 90% so positions stay consistent across devices.
- G5: Direct play first; universal-transcode HLS fallback when a codec fails (one automatic retry, then an honest error).
- G6: Lock-pause: playback pauses when the session locks, resumes on unlock (unlike Soma.fm, which deliberately keeps playing).

## 3. Non-goals

- No transcode-quality settings UI, no subtitle selection, no multi-server support.
- No library browsing beyond Continue Watching + search.

## 4. Security notes

- The X-Plex-Token travels only in HTTP headers for API calls — never URL query strings, which leak via process lists (`/proc/*/cmdline`), server logs, and cross-host redirects. API curls run `--fail` with redirect following disabled.
- Residual media-leg risk: mpv cannot read HTTP headers from a file, so its token header sits in argv. The default internal backend avoids argv exposure but QtMultimedia cannot set request headers, so direct-play/transcode carries the token in the media URL query and redirect handling is player-controlled. API requests remain header-only and non-redirecting. Rotating the token closes either exposure window.
- Server and token are validated at save time against strict shapes and stored chmod 600 in a 0700 directory; nothing user-controlled is interpolated into shell source.
- Server-derived part paths must be absolute library paths pinned to the configured origin; remote titles render `Text.PlainText`; mpv runs `--no-config --no-ytdl`.
- Curl transfer caps bound StdioCollector memory (4 MiB list/search, 2 MiB metadata); Model mapping re-bounds to 256 items and 256-character fields.

## 5. Testing

`node --test tests/*.test.mjs` — 12 tests over validServer/validToken (charset, length, path/query rejection), mapItems (onDeck shape, grouped search flattening without flatMap, empty containers), and fmtDuration (hour rollover, clamping).
