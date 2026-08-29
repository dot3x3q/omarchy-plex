# Plex API reference — Api.js

Everything below was verified live against the user's real Plex Media Server
(`~/.config/plexmini/config.json`) on 2026-08-28, not assembled from memory or
old Plex docs. Every endpoint returned `200`. Samples are trimmed to the
fields the mappers read (plus a few extras, to prove tolerance) and
sanitized: no token, no machine identifiers beyond the local library-section
UUIDs (harmless, not secrets), file paths shortened.

## Endpoints

| Endpoint | Status | Notes |
|---|---|---|
| `GET /library/sections` | 200 | `MediaContainer.Directory[]`, one per library |
| `GET /library/onDeck` | 200 | flat `MediaContainer.Metadata[]`, mixed movie/episode |
| `GET /library/sections/{id}/recentlyAdded` | 200 | flat `Metadata[]`, paginable |
| `GET /library/sections/{id}/all` | 200 | flat `Metadata[]`, sort param honored |
| `GET /library/metadata/{ratingKey}` | 200 | movie, show, season, episode all probed |
| `GET /library/metadata/{ratingKey}/children` | 200 | show→seasons, season→episodes |
| `GET /search?query=` | 200 | flat, pre-ranked, pre-typed |
| `GET /hubs/search?query=` | 200 | bucketed by type into `Hub[]` |
| `GET /photo/:/transcode?...&url=&X-Plex-Token=` | 200 `image/jpeg` | works with a server-relative path in `url=` |

## `/library/sections`

```json
{ "MediaContainer": { "Directory": [
  { "key": "1", "type": "movie", "title": "Movies" },
  { "key": "2", "type": "show", "title": "TV Shows" },
  { "key": "3", "type": "artist", "title": "Music" },
  { "key": "4", "type": "artist", "title": "Audiobooks" },
  { "key": "5", "type": "movie", "title": "Youtube" }
] } }
```

`mapSections` keeps `type === "movie" || "show"` only. This server also runs
`artist`-type libraries (Music, Audiobooks) — DESIGN.md's content scope
(movies + TV only) excludes those explicitly.

## `/library/onDeck` and `/library/sections/{id}/recentlyAdded`

Both return a **flat** `MediaContainer.Metadata[]` — no per-section grouping.
Shapes below cover the two item types that appear (movie, episode); a show
never appears directly in onDeck (its most-recent episode does).

**Movie** (`John Wick`, ratingKey `3291`):
```json
{
  "ratingKey": "3291", "type": "movie", "title": "John Wick",
  "year": 2014, "contentRating": "R",
  "viewOffset": 589738, "viewCount": 2, "duration": 6071798,
  "thumb": "/library/metadata/3291/thumb/1784798587",
  "art": "/library/metadata/3291/art/1784798587",
  "Genre": [{ "tag": "Action" }, { "tag": "Thriller" }]
}
```

**Episode** (`The Goddamn Brownies`, ratingKey `65501`, in progress):
```json
{
  "ratingKey": "65501", "type": "episode", "title": "The Goddamn Brownies",
  "grandparentTitle": "The 'Burbs", "parentIndex": 1, "index": 1,
  "viewOffset": 109599, "duration": 2501600,
  "thumb": "/library/metadata/65501/thumb/1779526677",
  "art": "/library/metadata/65496/art/1770694334",
  "grandparentArt": "/library/metadata/65496/art/1770694334",
  "grandparentThumb": "/library/metadata/65496/thumb/1770694334",
  "parentThumb": "/library/metadata/65497/thumb/1770693382"
}
```

### Shape surprises

- **No `viewCount` field at all on an in-progress episode** — not `0`,
  *absent*. `unwatchedFor()` treats "movie/episode with no viewCount" as
  unwatched (`!(Number(m.viewCount) > 0)`), not `viewCount === 0`, so an
  absent field doesn't accidentally read as watched.
- **Episode `art` already equals `grandparentArt`** — Plex resolves the
  fallback server-side. `artPathFor()` still checks both (`m.art ||
  m.grandparentArt`) for defense against a future response that omits `art`.
- Episodes never carry a `Genre` array — confirmed on both onDeck and the
  full `/library/metadata/{ratingKey}` response. `mapDetail`'s genre walk
  always produces `[]` rather than throwing on `undefined.length`.

### Pagination — headers vs query params (both work, identically)

Tested `X-Plex-Container-Start`/`X-Plex-Container-Size` on
`recentlyAdded` both as request headers and as query params on the same
endpoint; the response `MediaContainer.offset`/`size`/`totalSize` came back
identical either way (`size: 3, offset: 0, totalSize: 100` for
`start=0&size=3` against a 100-item Movies library). Api.js's URL builders
use the query-param form (`libraryAllUrl`, `recentlyAddedUrl`) since
`panel.request(path, cb)` builds one URL string per call — no per-call
header plumbing needed for a feature headers buy nothing over.

### `sort` on `/library/sections/{id}/all`

All three tried sorts are honored server-side (no client re-sort needed):

- `sort=addedAt:desc` — newest-added first (`Chloe` → `Sinister 2` → …)
- `sort=titleSort` — Plex's own title-sort, which strips leading articles
  and sorts punctuation before letters. `"The 'Burbs"` sorts as `"'Burbs"`
  and lands *before* `"3:10 to Yuma"` — looks unsorted at a glance but is
  correct once you know titleSort ignores "The"/"A"/"An" and treats `'`
  before digits before letters.
- `sort=year:desc` — newest release year first.

## `/library/metadata/{ratingKey}` — one per type

**Movie** — top-level `rating` (critic) *and* `audienceRating` both present:
```json
{
  "ratingKey": "3291", "type": "movie", "rating": 8.7, "audienceRating": 8.2,
  "summary": "...", "contentRating": "R", "duration": 6071798,
  "thumb": "/library/metadata/3291/thumb/...", "art": ".../art/...",
  "Genre": [{ "tag": "Action" }, { "tag": "Thriller" }],
  "Media": [{ "videoResolution": "4k", "container": "mkv", "videoCodec": "hevc",
              "audioCodec": "truehd", "width": 3840, "height": 2160, "bitrate": 69235 }]
}
```

**Show** — **no top-level `rating`**, only `audienceRating` + a `Rating[]`
array (`{image, value, type: "audience"|"critic"}` per source — IMDb,
Rotten Tomatoes, TMDB). No `Media` array (shows have no video file of their
own):
```json
{
  "ratingKey": "65496", "type": "show", "audienceRating": 5.2,
  "leafCount": 8, "viewedLeafCount": 0,
  "Genre": [{ "tag": "Comedy" }, { "tag": "Mystery" }, { "tag": "Suspense" }],
  "Rating": [
    { "image": "imdb://image.rating", "value": 6.4, "type": "audience" },
    { "image": "rottentomatoes://image.rating.ripe", "value": 7.6, "type": "critic" }
  ]
}
```
`mapDetail` falls back `rating: m.rating ?? m.audienceRating` so the detail
hero always has a number, regardless of type.

**Season** — no its own rating/Genre; carries `leafCount`/`viewedLeafCount`
same as a show (scoped to that season), `parentTitle` (show name),
`art`/`thumb` that fall back to the parent show's art when the season has no
distinct art of its own.

**Episode** — see onDeck sample above; full metadata adds `Media`/`Part`
(the playable file) but still **no `Genre`**, no top-level `rating`.

## `/library/metadata/{ratingKey}/children`

- On a **show** → `Metadata[]` of `type: "season"` (this show: 1 season, 8
  episodes: `leafCount: 8, viewedLeafCount: 0`).
- On a **season** → `Metadata[]` of `type: "episode"`, same shape as the
  onDeck episode sample.

## `/search` vs `/hubs/search` — decision: **`/search`**

Both probed with `?query=wick` and `?query=love` (the second to force a
mixed-media hit, since Plex's fuzzy search returned zero music matches for
"wick").

**`/search?query=`** — one flat, pre-ranked `MediaContainer.Metadata[]`,
each item already carrying its real `type`:
```
query=wick  → movie×8, episode×13   (Metadata[], typed, no wrapper)
query=love  → movie×15, show×5, episode×15, album×15
```
The second query proves **`/search` is not pre-filtered to video** — it
happily returns `type: "album"` hits too. `mapSearch` (and every other list
mapper) filters through an `{movie, show, season, episode}` allowlist for
this reason — DESIGN.md's content scope is movies + TV only, music stays in
the Spotify app's lane.

**`/hubs/search?query=`** — buckets results into per-type `Hub[]` entries
(`Movies`, `Episodes`, `Shows`, `Tracks`, `Actors`, `Directors`, `Genres`,
`Tags`, `Collections`, `Playlists`, …), each with its own `size` count. Item
shape inside a hub with actual media (`movie`, `episode`) is identical to
`/search`'s. But most hub types (`actor`, `director`, `genre`, `tag`,
`collection`, …) carry **no `Metadata` array at all** — just a hub `title`/
`size` with no item list — so consuming this endpoint means special-casing
which hub types are "real" media before you can build item shapes, for zero
benefit over `/search` (no shape richer than `/search`'s items, since the
non-empty hubs' items are the same shape).

**Chosen: `/search`.** Simpler (flat array, one filter pass), already
pre-typed, already how the pre-redesign `PlexPanel.qml` called Plex (`GET
/search?query=`) — this keeps behavior stable rather than introducing a new
endpoint dependency for no shape improvement. `/hubs/search`'s only real
advantage — per-type counts, for a "12 movies · 3 shows" summary line — isn't
part of the current contract; worth reconsidering only if a future page
wants type-count chips specifically.

## Image URLs — `/photo/:/transcode`

```
GET {server}/photo/:/transcode?width=W&height=H&minSize=1&upscale=1
    &url=<url-encoded path>&X-Plex-Token=<token>
→ 200, Content-Type: image/jpeg
```

Tested three `url=` forms — all three returned `200 image/jpeg`:
1. server-relative path only (`/library/metadata/3291/thumb/…`) — **chosen**
2. full absolute URL (`{server}/library/metadata/3291/thumb/…`)
3. token as a header instead of query, with the relative path — also fine,
   but Image (QML) can't send headers, hence the documented token-in-query
   exception (DESIGN.md "Known risks")

Api.js's `imageUrl()` uses form 1: the path Plex already hands back in
`thumb`/`art`/`grandparentArt` etc. is server-relative, so encoding it
directly is one step shorter than reassembling and re-encoding an absolute
URL, with identical results.

## Image path rules per type (`thumbPath` / `artPath` on every item)

| Type | `thumbPath` | `artPath` |
|---|---|---|
| movie | 2:3 poster (`thumb`) | wide backdrop (`art`) |
| show | 2:3 poster (`thumb`) | wide backdrop (`art`) |
| season | 2:3 poster (`thumb`, falls back to show's) | wide backdrop (`art`, falls back to show's) |
| episode | **landscape** 16:9 snapshot (`thumb`) | wide backdrop (`art`, falls back to `grandparentArt`) |

Both fields are always populated (empty string, never `undefined`, when the
source field is missing) so a component never has to null-check before
building an `Image.source`. Continue Watching rows want **landscape** art:
for episodes that's just `thumbPath` (already 16:9); for movies there's no
landscape thumb, so a CW row should use the movie's `artPath` instead. That
per-context pick belongs to the row component (`MediaRow.qml`), not to
Api.js — this file only guarantees both fields are correct for their type.

## Item shape (`itemFromMetadata`, contract-defined)

```js
{
  ratingKey, title,
  sub,             // episode: show name · season: show name · movie/show: year
  caption,         // episode: "SxEy" · season: "N episodes" · movie/show: contentRating
  thumbPath, artPath,
  type,            // movie | show | season | episode
  progress,        // viewOffset/duration, clamped 0..1, else 0
  durationText,    // "1h 52m" / "52m" / "2h" — ms formatted, whole hours drop "0m"
  year, unwatched  // bool for movie/episode; leafCount-viewedLeafCount for show/season
}
```

`sub`/`caption` are deliberately non-redundant by browse context
(DESIGN.md: posters for movie/show/season, rows for episodes/search/CW) so
either `MediaRow` (title + `sub`) or `PosterCard` (title + `caption`) reads
sensibly without either component needing type-specific logic of its own.

`mapDetail` adds, on top of the base shape: `summary`, `rating` (top-level
`rating` if present, else `audienceRating`, else `null`), `contentRating`,
`genres` (always an array), and `media` (`null` for show/season, `{
videoResolution, container, videoCodec, audioCodec, width, height, bitrate
}` for movie/episode).

## Audio and subtitle streams — `Media[].Part[].Stream[]`

Verified live 2026-08-29 against the same server (PMS `1.43.3.10896`), on
*Akira* (`ratingKey 245`, `Part.id 524`) and a *Jujutsu Kaisen* episode
(11 audio streams, 20 subtitle streams). `streamType` discriminates:
**1 = video, 2 = audio, 3 = subtitle.**

```json
{ "MediaContainer": { "Metadata": [ { "Media": [ { "Part": [ {
  "id": 524,
  "key": "/library/parts/524/1718768365/file.mkv",
  "container": "mkv", "duration": 7486480,
  "Stream": [
    { "id": 1513, "streamType": 1, "default": true, "codec": "hevc", "index": 0,
      "displayTitle": "4K DoVi/HDR10",
      "extendedDisplayTitle": "4K DoVi/HDR10 (HEVC Main 10)" },

    { "id": 1514, "streamType": 2, "codec": "truehd", "index": 1, "channels": 8,
      "language": "日本語", "languageTag": "ja", "languageCode": "jpn",
      "audioChannelLayout": "7.1",
      "displayTitle": "日本語 (TRUEHD 7.1 + Atmos)",
      "extendedDisplayTitle": "日本語 (TRUEHD 7.1 + Atmos)" },
    { "id": 1515, "streamType": 2, "selected": true, "codec": "truehd", "index": 2,
      "channels": 6, "language": "English",
      "displayTitle": "English (TRUEHD 5.1)",
      "extendedDisplayTitle": "English (TRUEHD 5.1)" },
    { "id": 1516, "streamType": 2, "default": true, "codec": "ac3", "index": 3,
      "channels": 6, "language": "Italiano", "title": "Nuovo doppiaggio",
      "displayTitle": "Italiano (AC3 5.1)",
      "extendedDisplayTitle": "Nuovo doppiaggio (Italiano AC3 5.1)" },

    { "id": 1518, "streamType": 3, "codec": "pgs", "index": 5, "language": "English",
      "displayTitle": "English", "extendedDisplayTitle": "English (PGS)" },
    { "id": 1519, "streamType": 3, "selected": true, "forced": true, "codec": "pgs",
      "index": 6, "language": "English", "title": "(Foreign)",
      "displayTitle": "English Forced",
      "extendedDisplayTitle": "(Foreign) (English Forced PGS)" },
    { "id": 1521, "streamType": 3, "default": true, "codec": "srt", "index": 8,
      "language": "Italiano", "title": "Forced",
      "displayTitle": "Italiano", "extendedDisplayTitle": "Forced (Italiano SRT)" }
  ]
} ] } ] } ] } }
```

### Shape surprises

- **`selected`, `default` and `forced` are omitted entirely when false** —
  never serialized as `false`. Held on every one of ~15 items and 60+
  streams probed, including the 20-subtitle episode where nineteen of them
  simply have no `selected` key. The test is `stream.selected === true`;
  anything that assumes the key exists reads `undefined` and misbehaves.
  `Api.streamFlag()` is the single place that decides this.
- **`id`, `index`, `streamType` and `Part.id` are JSON numbers, not strings**
  (unlike `ratingKey`, which is a string). `mapStreams` normalizes ids to
  strings on the way out so URL building never has to care.
- **`index` counts across ALL stream types in container order** — on Akira:
  video 0, audio 1–4, subtitles 5–8. It is therefore *not* what a player
  wants. QtMultimedia's `audioTracks[]` index and mpv's `aid`/`sid` both
  count within one type, so `mapStreams` synthesizes an `ordinal` field for
  that and leaves `index` alone.
- **`extendedDisplayTitle` is not a template you can rebuild.** Its
  composition reorders depending on whether a custom `title` exists, whether
  the stream is `forced`, and whether `language` is Plex's canonical name for
  itself. Compare `"English (TRUEHD 5.1)"` (no title) against
  `"Nuovo doppiaggio (Italiano AC3 5.1)"` (title hoisted to the front,
  language moved inside the parens) and
  `"Español (Latin America) [Crunchyroll] (Español (Latinoamérica) AAC Stereo)"`.
  Take it verbatim. It is also the only field that separates two dubs of the
  same language, which is exactly what a picker exists for — hence
  `streamLabel()` preferring it over `displayTitle`.
- **Two different "Forced" naming patterns exist and are not
  interchangeable**: `"(Foreign) (English Forced PGS)"` comes from
  `forced: true`, while `"Forced (Italiano SRT)"` comes from an arbitrary
  source `title` that happens to read "Forced".
- **`hearingImpaired`, `dub`, `key` and `format` appear on no stream
  anywhere** in the sample (~15 items, 60+ streams). Absence is the normal
  case, not an anomaly.
- **No sidecar/external subtitle stream was found** — nothing carrying its
  own `key`. This library is 100% muxed. `mapStreams`'s `external` branch
  (and `ordinal: -1` for it) is therefore *defensive, not verified*; the
  behavior is pinned by a unit test rather than by a live capture.
- **No multi-part item was found** (`Media[0].Part.length > 1`) across 11
  movies and 5 episodes. `mapStreams` reads `Part[0]` only; `allParts=1` on
  the selection PUT keeps the halves in step if one ever turns up.

### `PUT /library/parts/{partId}` — server-side track selection

```
PUT {server}/library/parts/524?audioStreamID=1516&subtitleStreamID=1518&allParts=1
→ 200, empty body
```

Verified live, all four cases, then restored to the original selection:

- **No extra headers required.** `X-Plex-Token` alone works; no
  `X-Plex-Client-Identifier` needed (the panel sends one anyway — it reuses
  `plexHeaders`, which keeps the token out of the query string).
- **The two params are independent.** An audio-only PUT left the subtitle
  selection untouched, and vice versa. Neither clears the other.
- **`subtitleStreamID=0` means "no subtitles"** — after it, zero subtitle
  streams came back carrying `selected`.
- Re-GETting `/library/metadata/{ratingKey}` confirmed the `selected` flags
  actually moved each time.

This is the mechanism that makes a track choice survive into a **transcode**:
the server builds the new stream from whatever is selected on the part, so
the PUT has to land *before* the transcode is requested. `PlexPanel.qml`
therefore hangs the restart off the PUT process's `onExited` rather than
racing it.

### Which mechanism applies, per backend

| Situation | How the choice is applied |
|---|---|
| Internal backend, direct play, lists aligned | `player.activeAudioTrack` / `activeSubtitleTrack` by `ordinal` — instant, no restart. PUT also sent, so a later transcode inherits it |
| Internal backend, transcoding already | PUT, then restart the transcode at the current position (`resumeSec`) — a transcode carries one audio track, so there is nothing local to switch |
| Internal backend, image subtitle (PGS/VOBSUB) | PUT + transcode restart. Qt's ffmpeg backend only ever reads a subtitle rect's **text** payload (`.text`/`.ass`); the bitmap payload is never touched, so these cannot render in-window at all. Not a corner case — Akira ships three image tracks and one SRT |
| Internal backend, sidecar stream | PUT + transcode restart (nothing in the container to select) |
| mpv backend | IPC `set_property aid`/`sid` with `ordinal + 1` (mpv numbers from 1, per type), plus the PUT. `sid "no"` for none. Best-effort: matching mpv's mux order to Plex's Stream order is an assumption with no cheap readback to confirm it |

Track lists on the internal player are only readable once the demuxer has
resolved the streams, and Qt throws *"Cannot set active track without open
source"* if written before that — `playerTracksReady` gates on
`LoadedMedia`/`BufferedMedia`/`BufferingMedia` for both reasons. When the
player's track count and Plex's embedded count disagree
(`playerTracksAligned` false — the usual cause being a transcode), the
ordinals are meaningless and every pick is routed back to the server.
