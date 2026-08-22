# Plex Mini for Omarchy

A small floating Plex player and remote for the Omarchy shell. Continue Watching and full library search in a miniwindow; playback launches in standalone **mpv with hardware decode** (`--hwdec=auto --vo=gpu-next`) so movies and shows render on your dGPU while you work. The panel doubles as a remote over mpv's JSON IPC socket.

Works alongside [plex-mpv-shim](https://github.com/iwalton3/plex-mpv-shim) — same engine, no conflicts. Watch progress is reported back to your server every 10 seconds and items are marked watched at 90%, so positions stay in sync across your devices.

## Install

From Omarchy Plugin Control (Super+Shift+P → Plugins), search for **Plex Mini** and install — or run the install command shown on the plugin's marketplace page.

## Remove

Uninstall from Omarchy Plugin Control, then delete config and state if you want a fully clean slate:

```
rm -rf ~/.config/plexmini ~/.local/state/plexmini
```

## External dependencies

- `mpv` — default playback backend (`sudo pacman -S mpv`)
- `socat` — remote control over mpv's IPC socket (`sudo pacman -S socat`)
- `curl` (included with Omarchy) — talks to your Plex server

Setting `"backend": "internal"` in the config plays inside the panel via QtMultimedia instead and drops the mpv/socat requirements.

## Setup

1. Open Plex Mini from the bar (or command palette)
2. Enter your server URL, e.g. `http://192.168.1.50:32400`
3. Enter an X-Plex-Token:
   - Sign in at app.plex.tv, play anything, and copy the `X-Plex-Token` query parameter from the page URL, **or**
   - Fetch `https://plex.tv/api/resources?includeHttps=1&X-Plex-Token=...` after obtaining a token via the plex.tv/devices flow
4. Press Enter — the token is stored chmod 600 in `~/.config/plexmini/config.json`

Config file format:

```json
{ "server": "http://192.168.1.50:32400", "token": "YOUR_TOKEN", "backend": "mpv" }
```

## Usage

- Pick from **Continue Watching** or search your library (movies, shows, episodes)
- Playback opens in an mpv window using your GPU for decode; the panel shows position, pause state, and controls (±30s, seek bar, stop)
- Keyboard: `Space` pause, `←/→` seek 30s, `Esc` hide panel
- Direct play is tried first; unsupported codecs automatically fall back to server transcoding (HLS)

## License

MIT — see [LICENSE](LICENSE).
