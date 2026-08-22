# Plex Mini — Marketplace Listing

## Submission title

`[Plugin]: Plex Mini`

## Category

Widgets

## Tags

media, quickshell

## Short description

A resizable Plex miniplayer for Omarchy: Continue Watching, live type-to-search, resume, keyboard transport controls, watch-progress sync, and transcode fallback in one floating panel.

## Maintainer notes

Plex Mini is a theme-aware Quickshell panel with an optional bar widget. It opens into Continue Watching with immediate live search (300 ms debounce), full keyboard navigation, and a resizable ytmini-style in-panel player. Direct playback seeks to Plex's stored `viewOffset`, reports timeline progress every 10 seconds, scrobbles at 90%, pauses on close/lock, and falls back once to universal-transcode HLS when direct play fails. Default playback uses QtMultimedia; an opt-in mpv backend provides separate dGPU-backed playback. Credentials are validated and stored chmod 600. API transfers and model mapping are explicitly bounded. Pure logic lives in Model.js with 11 passing node:test tests, including static QML integration contracts. External dependency: curl; optional mpv mode also needs mpv + socat.

## Submission body

### Repository URL

https://github.com/joshuaswarren/omarchy-plexmini

### Category

Widgets

### Tags

media, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

Plex Mini is a theme-aware Quickshell panel with an optional bar widget. It opens into Continue Watching with immediate live search (300 ms debounce), full keyboard navigation, and a resizable ytmini-style in-panel player. Direct playback seeks to Plex's stored `viewOffset`, reports timeline progress every 10 seconds, scrobbles at 90%, pauses on close/lock, and falls back once to universal-transcode HLS when direct play fails. Default playback uses QtMultimedia; an opt-in mpv backend provides separate dGPU-backed playback. Credentials are validated and stored chmod 600. API transfers and model mapping are explicitly bounded. Pure logic lives in Model.js with 11 passing node:test tests, including static QML integration contracts. External dependency: curl; optional mpv mode also needs mpv + socat.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
