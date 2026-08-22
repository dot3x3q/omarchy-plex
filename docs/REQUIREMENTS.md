# Plex Mini — Requirements

Status: **implemented** (v0.1.0, live-verified on Omarchy 4 / Quattro)
Target: Omarchy 4 / Quattro shell (Quickshell plugin API)
Plugin ID: `io.github.joshuaswarren.plexmini`
Kind: `panel` + `bar-widget`

## 1. Problem

Watching something from your own Plex library while working means a full Plex client fighting for screen space, or casting to a shim and losing all controls to a phone. Nothing gives you "pick from Continue Watching, play it small, keep working" in one surface.

## 2. Goals

- G1: Continue Watching on open; full library search (`/search`) in the same list.
- G2: Playback launches in standalone mpv with hardware decode (`--hwdec=auto --vo=gpu-next`) — dGPU decode by default, same engine as plex-mpv-shim, so the two coexist.
- G3: The panel is the remote: selection outline, `Space` pause, `Left`/`Right` seek 30s, click-to-seek, stop — driven over mpv's JSON IPC socket.
- G4: Watch progress reported via `//:/timeline` every 10s; scrobbled at 90% so positions stay consistent across devices.
- G5: Direct play first; universal-transcode HLS fallback when a codec fails (one automatic retry, then an honest error).
- G6: Lock-pause: playback pauses when the session locks, resumes on unlock (unlike Soma.fm, which deliberately keeps playing).

## 3. Non-goals

- No transcode-quality settings UI, no subtitle selection, no multi-server support.
- No library browsing beyond Continue Watching + search.

## 4. Security notes

- The X-Plex-Token travels only in HTTP headers for API calls — never URL query strings, which leak via process lists (`/proc/*/cmdline`), server logs, and cross-host redirects. API curls run `--fail` with redirect following disabled.
- Residual risk, accepted for a single-user desktop: mpv cannot read HTTP headers from a file, so the direct-play token header sits in mpv's argv. Rotating the token closes any window; the transcode URL keeps its query-token because HLS segment fetches need it, and that URL exists only inside the local mpv process.
- Server and token are validated at save time against strict shapes and stored chmod 600 in a 0700 directory; nothing user-controlled is interpolated into shell source.
- Server-derived part paths must be absolute library paths pinned to the configured origin; remote titles render `Text.PlainText`; mpv runs `--no-config --no-ytdl`.

## 5. Testing

`node --test tests/model.test.mjs` — 7 tests over validServer/validToken (charset, length, path/query rejection), mapItems (onDeck shape, grouped search flattening without flatMap, empty containers), and fmtDuration (hour rollover, clamping).
