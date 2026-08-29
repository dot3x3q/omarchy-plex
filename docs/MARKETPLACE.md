# omarchy-plex — Marketplace Listing (draft, submit after the repo is public)

## Submission title

`[Plugin]: omarchy-plex`

## Category

Widgets

## Tags

media, quickshell, plex, video

## Short description

A full Plex player for Omarchy: sidebar library browsing with poster grids
and detail pages, theater + minibar playback, multi-monitor picture-in-picture,
audio/subtitle/quality selection, and an optional native libmpv engine with
hardware decode and HDR tone mapping.

## Maintainer notes

omarchy-plex is a theme-aware Quickshell panel (plus bar widget with a
now-playing marquee) built entirely on Omarchy's shared shell kit, so it
follows the system theme live. It browses movie/TV libraries (Home with On
Deck and Recently Added, poster grids, season/episode detail pages), searches
the whole server as you type, and plays in a real tiling-tree window with a
theater view, a browse-while-playing minibar, and a click-through
picture-in-picture card that can be dragged across monitors with a live
drop-preview ghost. Playback is three-tier: an optional compiled libmpv QML
module (hardware decode, HDR tone mapping, native PGS/VOBSUB subtitles,
header-only token auth) with automatic fallback to QtMultimedia when the
module is absent, plus an opt-in external-mpv mode. Audio/subtitle/stream
quality are selectable mid-playback; server-side selections survive
transcodes. Timeline progress, resume from viewOffset, 90% scrobble, and
pause-on-close/lock are all handled. Credentials are validated and stored
chmod 600 with bounded atomic IO; API transfers are size- and time-bounded;
50+ node:test tests including static contract pins over the QML. External
dependency: curl. Optional: mpvqt+cmake to build the native module; mpv+socat
for the external backend.

## Submission body

### Repository URL

https://github.com/dot3x3q/omarchy-plex

### Category

Widgets

### Tags

media, quickshell, plex, video

### Submission checklist

- [ ] The repository is public and contains installation and removal instructions.
- [ ] I have documented the plugin license and any external dependencies.
- [ ] I confirm that I own or have permission to submit this plugin and its preview assets.
- [ ] The plugin does not overwrite user configuration without explicit consent.
- [ ] I understand that approval is for listing and is not a security review.

Grew out of joshuaswarren/omarchy-plexmini (MIT, credited in LICENSE and
README).
