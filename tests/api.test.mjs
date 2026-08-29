// Api.js unit tests. Same loading convention as model.test.mjs: the QML script
// (plain function declarations, no module syntax) runs under node:vm. Fixtures
// are trimmed, sanitized captures from a real Plex Media Server: field names
// and shapes are real; tokens, machine identifiers and absolute file paths are
// stripped or shortened. Keep it that way when adding fixtures.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Api.js"), "utf8")

const ctx = vm.createContext({})
vm.runInNewContext(
  source +
    "\nthis.A = { sectionsUrl, onDeckUrl, recentlyAddedUrl, libraryAllUrl, metadataUrl," +
    " childrenUrl, searchUrl, imageUrl, mapSections, mapItems, mapSearch, mapChildren," +
    " mapDetail, durationText: durationText, progressFor: progressFor, unwatchedFor: unwatchedFor," +
    " mapStreams, selectedStreamId, partSelectionUrl, streamLabel }",
  ctx
)
const A = ctx.A

// ---- URL builders ----

test("sectionsUrl / onDeckUrl are plain paths", () => {
  assert.equal(A.sectionsUrl("http://s:32400"), "http://s:32400/library/sections")
  assert.equal(A.onDeckUrl("http://s:32400"), "http://s:32400/library/onDeck")
})

test("recentlyAddedUrl adds pagination only when a size is given", () => {
  assert.equal(A.recentlyAddedUrl("http://s:32400", 1), "http://s:32400/library/sections/1/recentlyAdded")
  assert.equal(
    A.recentlyAddedUrl("http://s:32400", 1, 12),
    "http://s:32400/library/sections/1/recentlyAdded?X-Plex-Container-Start=0&X-Plex-Container-Size=12"
  )
})

test("libraryAllUrl composes sort + pagination params", () => {
  assert.equal(A.libraryAllUrl("http://s:32400", 1, {}), "http://s:32400/library/sections/1/all")
  assert.equal(
    A.libraryAllUrl("http://s:32400", 1, { sort: "addedAt:desc" }),
    "http://s:32400/library/sections/1/all?sort=addedAt:desc"
  )
  assert.equal(
    A.libraryAllUrl("http://s:32400", 1, { sort: "titleSort", start: 0, size: 50 }),
    "http://s:32400/library/sections/1/all?sort=titleSort&X-Plex-Container-Start=0&X-Plex-Container-Size=50"
  )
})

test("metadataUrl / childrenUrl / searchUrl", () => {
  assert.equal(A.metadataUrl("http://s:32400", "3291"), "http://s:32400/library/metadata/3291")
  assert.equal(A.childrenUrl("http://s:32400", "65496"), "http://s:32400/library/metadata/65496/children")
  assert.equal(A.searchUrl("http://s:32400", " wick "), "http://s:32400/search?query=wick")
})

test("imageUrl encodes a server-relative path and appends the token last", () => {
  const u = A.imageUrl("http://s:32400", "TOK123", "/library/metadata/3291/thumb/999", 300, 450)
  assert.equal(
    u,
    "http://s:32400/photo/:/transcode?width=300&height=450&minSize=1&upscale=1&url=%2Flibrary%2Fmetadata%2F3291%2Fthumb%2F999&X-Plex-Token=TOK123"
  )
})

test("imageUrl returns empty string for a missing path (no glyph-breaking Image src)", () => {
  assert.equal(A.imageUrl("http://s:32400", "TOK123", "", 300, 450), "")
  assert.equal(A.imageUrl("http://s:32400", "TOK123", undefined, 300, 450), "")
})

// ---- mapSections ----

const sectionsFixture = {
  MediaContainer: {
    Directory: [
      { key: "1", type: "movie", title: "Movies" },
      { key: "2", type: "show", title: "TV Shows" },
      { key: "3", type: "artist", title: "Music" },
      { key: "4", type: "artist", title: "Audiobooks" },
      { key: "5", type: "movie", title: "Youtube" }
    ]
  }
}

test("mapSections keeps only movie/show libraries", () => {
  const out = A.mapSections(sectionsFixture)
  assert.equal(out.length, 3)
  assert.equal(out.map(s => s.type).join("|"), "movie|show|movie")
  assert.ok(!out.some(s => s.title === "Music" || s.title === "Audiobooks"))
})

// ---- mapItems (onDeck / recentlyAdded / library/all all share this shape) ----

const movieItem = {
  ratingKey: "3291",
  type: "movie",
  title: "John Wick",
  year: 2014,
  contentRating: "R",
  viewOffset: 589738,
  viewCount: 2,
  duration: 6071798,
  thumb: "/library/metadata/3291/thumb/1",
  art: "/library/metadata/3291/art/1"
}

const episodeItem = {
  ratingKey: "65501",
  type: "episode",
  title: "The Goddamn Brownies",
  grandparentTitle: "The 'Burbs",
  parentIndex: 1,
  index: 1,
  viewOffset: 109599,
  duration: 2501600,
  thumb: "/library/metadata/65501/thumb/1",
  art: "/library/metadata/65496/art/1",
  grandparentArt: "/library/metadata/65496/art/1"
  // note: no viewCount field at all, which is what an in-progress episode sends
}

test("mapItems maps a movie with viewOffset/duration into progress + durationText", () => {
  const out = A.mapItems({ MediaContainer: { Metadata: [movieItem] } })
  assert.equal(out.length, 1)
  const m = out[0]
  assert.equal(m.ratingKey, "3291")
  assert.equal(m.title, "John Wick")
  assert.equal(m.sub, "2014")
  assert.equal(m.caption, "R")
  assert.equal(m.thumbPath, "/library/metadata/3291/thumb/1")
  assert.equal(m.artPath, "/library/metadata/3291/art/1")
  assert.ok(m.progress > 0 && m.progress < 1)
  assert.equal(m.durationText, "1h 41m")
  assert.equal(m.unwatched, false) // viewCount: 2
})

test("mapItems maps an episode: show name as sub, SxEy as caption, landscape thumb", () => {
  const out = A.mapItems({ MediaContainer: { Metadata: [episodeItem] } })
  const e = out[0]
  assert.equal(e.sub, "The 'Burbs")
  assert.equal(e.caption, "S1E1")
  assert.equal(e.thumbPath, "/library/metadata/65501/thumb/1")
  assert.equal(e.artPath, "/library/metadata/65496/art/1")
  assert.equal(e.unwatched, true) // viewCount absent entirely, not just 0
})

test("mapItems tolerates missing thumb/art/viewOffset/Genre without throwing", () => {
  const bare = { ratingKey: "1", type: "movie", title: "Bare" }
  const out = A.mapItems({ MediaContainer: { Metadata: [bare] } })
  assert.equal(out.length, 1)
  assert.equal(out[0].thumbPath, "")
  assert.equal(out[0].artPath, "")
  assert.equal(out[0].progress, 0)
  assert.equal(out[0].durationText, "0m")
})

test("mapItems drops non-video types and tolerates an empty/null container", () => {
  const mixed = {
    MediaContainer: {
      Metadata: [
        { ratingKey: "1", type: "movie", title: "Movie" },
        { ratingKey: "2", type: "album", title: "Some Album" },
        { ratingKey: "3", type: "artist", title: "Some Artist" },
        { ratingKey: "4", type: "track", title: "Some Track" }
      ]
    }
  }
  assert.equal(A.mapItems(mixed).length, 1)
  assert.equal(A.mapItems(null).length, 0)
  assert.equal(A.mapItems({ MediaContainer: {} }).length, 0)
})

test("mapItems caps item count at 256", () => {
  const meta = Array.from({ length: 400 }, (_, i) => ({ ratingKey: "k" + i, type: "movie", title: "T" }))
  assert.equal(A.mapItems({ MediaContainer: { Metadata: meta } }).length, 256)
})

// ---- mapSearch: /search mixes in music hits for a broad query, live-confirmed ----

test("mapSearch filters out album/artist/track hits, keeps movie/show/episode", () => {
  const searchFixture = {
    MediaContainer: {
      size: 4,
      Metadata: [
        { ratingKey: "1", type: "movie", title: "John Wick" },
        { ratingKey: "2", type: "episode", title: "Wicked Lips", grandparentTitle: "Show" },
        { ratingKey: "3", type: "album", title: "Wicked (Soundtrack)" },
        { ratingKey: "4", type: "artist", title: "Wicked Cast" }
      ]
    }
  }
  const out = A.mapSearch(searchFixture)
  assert.equal(out.map(i => i.type).join("|"), "movie|episode")
})

// ---- mapChildren: show -> seasons, season -> episodes ----

test("mapChildren maps a show's seasons", () => {
  const seasonsFixture = {
    MediaContainer: {
      Metadata: [
        { ratingKey: "65497", type: "season", title: "Season 1", parentTitle: "The 'Burbs", leafCount: 8, viewedLeafCount: 0 }
      ]
    }
  }
  const out = A.mapChildren(seasonsFixture)
  assert.equal(out[0].title, "Season 1")
  assert.equal(out[0].sub, "The 'Burbs")
  assert.equal(out[0].caption, "8 episodes")
  assert.equal(out[0].unwatched, 8) // leafCount - viewedLeafCount
})

test("mapChildren maps a season's episodes", () => {
  const episodesFixture = {
    MediaContainer: {
      Metadata: [
        { ratingKey: "65501", type: "episode", title: "The Goddamn Brownies", grandparentTitle: "The 'Burbs", parentIndex: 1, index: 1 },
        { ratingKey: "65502", type: "episode", title: "Mind Your Own Business", grandparentTitle: "The 'Burbs", parentIndex: 1, index: 2 }
      ]
    }
  }
  const out = A.mapChildren(episodesFixture)
  assert.equal(out.length, 2)
  assert.equal(out[1].caption, "S1E2")
})

// ---- mapDetail ----

test("mapDetail on a movie: top-level rating, genres, Media info", () => {
  const movieDetail = {
    MediaContainer: {
      Metadata: [
        {
          ratingKey: "3291",
          type: "movie",
          title: "John Wick",
          year: 2014,
          summary: "A former hitman seeks revenge.",
          rating: 8.7,
          audienceRating: 8.2,
          contentRating: "R",
          duration: 6071798,
          thumb: "/library/metadata/3291/thumb/1",
          art: "/library/metadata/3291/art/1",
          Genre: [{ tag: "Action" }, { tag: "Thriller" }],
          Media: [{ videoResolution: "4k", container: "mkv", videoCodec: "hevc", audioCodec: "truehd", width: 3840, height: 2160, bitrate: 69235 }]
        }
      ]
    }
  }
  const d = A.mapDetail(movieDetail)
  assert.equal(d.rating, 8.7) // prefers top-level rating over audienceRating
  assert.equal(d.genres.join("|"), "Action|Thriller")
  assert.equal(d.media.videoResolution, "4k")
  assert.equal(d.media.width, 3840)
  assert.match(d.summary, /revenge/)
})

test("mapDetail on a show: falls back to audienceRating, tolerates absent Media", () => {
  const showDetail = {
    MediaContainer: {
      Metadata: [
        {
          ratingKey: "65496",
          type: "show",
          title: "The 'Burbs",
          year: 2026,
          audienceRating: 5.2,
          contentRating: "TV-MA",
          leafCount: 8,
          viewedLeafCount: 0,
          thumb: "/library/metadata/65496/thumb/1",
          art: "/library/metadata/65496/art/1",
          Genre: [{ tag: "Comedy" }, { tag: "Mystery" }]
        }
      ]
    }
  }
  const d = A.mapDetail(showDetail)
  assert.equal(d.rating, 5.2) // shows carry no top-level `rating`
  assert.equal(d.media, null)
  assert.equal(d.unwatched, 8)
})

test("mapDetail on an episode: no Genre field at all, never throws", () => {
  const episodeDetail = {
    MediaContainer: {
      Metadata: [
        {
          ratingKey: "65501",
          type: "episode",
          title: "The Goddamn Brownies",
          grandparentTitle: "The 'Burbs",
          parentIndex: 1,
          index: 1,
          contentRating: "TV-MA",
          duration: 2501600,
          viewOffset: 109599
          // no Genre, no thumb/art, no rating — all real response shapes
        }
      ]
    }
  }
  const d = A.mapDetail(episodeDetail)
  assert.equal(d.genres.length, 0)
  assert.equal(d.rating, null)
  assert.equal(d.thumbPath, "")
})

test("mapDetail returns null for an empty container instead of throwing", () => {
  assert.equal(A.mapDetail({ MediaContainer: { Metadata: [] } }), null)
  assert.equal(A.mapDetail(null), null)
})

// ---- durationText / progressFor / unwatchedFor edge cases ----

test("durationText formats ms as Nh Nm, dropping a zero-minute remainder", () => {
  assert.equal(A.durationText(52 * 60000), "52m")
  assert.equal(A.durationText((1 * 3600 + 52 * 60) * 1000), "1h 52m")
  assert.equal(A.durationText(2 * 3600 * 1000), "2h")
  assert.equal(A.durationText(0), "0m")
  assert.equal(A.durationText(undefined), "0m")
})

test("progressFor clamps and tolerates missing/zero fields", () => {
  assert.equal(A.progressFor({ viewOffset: 500, duration: 1000 }), 0.5)
  assert.equal(A.progressFor({ viewOffset: 5000, duration: 1000 }), 1)
  assert.equal(A.progressFor({}), 0)
  assert.equal(A.progressFor({ viewOffset: 500, duration: 0 }), 0)
  assert.equal(A.progressFor(null), 0)
})

test("unwatchedFor: bool for movie/episode, count for show/season", () => {
  assert.equal(A.unwatchedFor({ type: "movie", viewCount: 2 }), false)
  assert.equal(A.unwatchedFor({ type: "movie" }), true) // viewCount absent
  assert.equal(A.unwatchedFor({ type: "episode", viewCount: 0 }), true)
  assert.equal(A.unwatchedFor({ type: "show", leafCount: 8, viewedLeafCount: 3 }), 5)
  assert.equal(A.unwatchedFor({ type: "season", leafCount: 8, viewedLeafCount: 8 }), 0)
})

// ---- audio / subtitle streams ----
//
// Api.js runs inside a node:vm context, so anything it returns is built from
// THAT realm's Array/Object prototypes and assert's deep comparison rejects it
// against a literal written out here — identical contents, different
// prototype. Round-tripping through JSON re-homes the value in this realm.
// (The mappers above sidestep this by only ever asserting scalars.)
const plain = v => JSON.parse(JSON.stringify(v))
//
// Fixture is a trimmed capture of the real /library/metadata/245 response
// (Akira, 1988 — 4 audio tracks including two different Italian dubs, and 4
// subtitle tracks of which exactly one is a text format). Nothing here is
// invented: the flag-omission pattern, the index numbering across types, and
// the extendedDisplayTitle shapes are all verbatim from the live server. See
// docs/PLEX-API.md.
const akiraStreams = {
  MediaContainer: {
    Metadata: [{
      ratingKey: "245", type: "movie", title: "Akira",
      Media: [{
        container: "mkv", videoCodec: "hevc",
        Part: [{
          id: 524,
          key: "/library/parts/524/1718768365/file.mkv",
          duration: 7486480,
          container: "mkv",
          Stream: [
            { id: 1513, streamType: 1, default: true, codec: "hevc", index: 0,
              language: "English", languageTag: "en", languageCode: "eng",
              displayTitle: "4K DoVi/HDR10",
              extendedDisplayTitle: "4K DoVi/HDR10 (HEVC Main 10)" },
            { id: 1514, streamType: 2, codec: "truehd", index: 1, channels: 8,
              language: "日本語", languageTag: "ja", languageCode: "jpn",
              audioChannelLayout: "7.1",
              displayTitle: "日本語 (TRUEHD 7.1 + Atmos)",
              extendedDisplayTitle: "日本語 (TRUEHD 7.1 + Atmos)" },
            { id: 1515, streamType: 2, selected: true, codec: "truehd", index: 2, channels: 6,
              language: "English", languageTag: "en", languageCode: "eng",
              displayTitle: "English (TRUEHD 5.1)",
              extendedDisplayTitle: "English (TRUEHD 5.1)" },
            { id: 1516, streamType: 2, default: true, codec: "ac3", index: 3, channels: 6,
              language: "Italiano", languageTag: "it", languageCode: "ita",
              title: "Nuovo doppiaggio",
              displayTitle: "Italiano (AC3 5.1)",
              extendedDisplayTitle: "Nuovo doppiaggio (Italiano AC3 5.1)" },
            { id: 1517, streamType: 2, codec: "ac3", index: 4, channels: 2,
              language: "Italiano", languageTag: "it", languageCode: "ita",
              title: "Doppiaggio Storico",
              displayTitle: "Italiano (AC3 Stereo)",
              extendedDisplayTitle: "Doppiaggio Storico (Italiano AC3 Stereo)" },
            { id: 1518, streamType: 3, canAutoSync: false, codec: "pgs", index: 5,
              language: "English", languageTag: "en", languageCode: "eng",
              displayTitle: "English", extendedDisplayTitle: "English (PGS)" },
            { id: 1519, streamType: 3, canAutoSync: false, selected: true, forced: true,
              codec: "pgs", index: 6, language: "English", languageTag: "en", languageCode: "eng",
              title: "(Foreign)", displayTitle: "English Forced",
              extendedDisplayTitle: "(Foreign) (English Forced PGS)" },
            { id: 1520, streamType: 3, canAutoSync: false, codec: "vobsub", index: 7,
              language: "Italiano", languageTag: "it", languageCode: "ita",
              displayTitle: "Italiano", extendedDisplayTitle: "Italiano (VOBSUB)" },
            { id: 1521, streamType: 3, canAutoSync: false, default: true, codec: "srt", index: 8,
              language: "Italiano", languageTag: "it", languageCode: "ita", title: "Forced",
              displayTitle: "Italiano", extendedDisplayTitle: "Forced (Italiano SRT)" }
          ]
        }]
      }]
    }]
  }
}

test("mapStreams buckets by streamType and exposes the part id as a string", () => {
  const s = A.mapStreams(akiraStreams)
  assert.equal(s.partId, "524") // arrives as a JSON number, leaves as a string
  assert.equal(s.video.length, 1)
  assert.equal(s.audio.length, 4)
  assert.equal(s.subtitle.length, 4)
  assert.deepEqual(plain(s.audio.map(a => a.id)), ["1514", "1515", "1516", "1517"])
})

test("mapStreams ordinal counts within a type, unlike Plex's cross-type index", () => {
  const s = A.mapStreams(akiraStreams)
  // Plex numbers `index` across the whole container: video 0, audio 1-4,
  // subtitles 5-8. Players count per type, which is what `ordinal` is for.
  assert.deepEqual(plain(s.audio.map(a => a.index)), [1, 2, 3, 4])
  assert.deepEqual(plain(s.audio.map(a => a.ordinal)), [0, 1, 2, 3])
  assert.deepEqual(plain(s.subtitle.map(a => a.index)), [5, 6, 7, 8])
  assert.deepEqual(plain(s.subtitle.map(a => a.ordinal)), [0, 1, 2, 3])
})

test("mapStreams reads absent selected/default/forced as false", () => {
  const s = A.mapStreams(akiraStreams)
  // Plex omits these keys entirely rather than sending false.
  assert.deepEqual(plain(s.audio.map(a => a.selected)), [false, true, false, false])
  assert.deepEqual(plain(s.audio.map(a => a.isDefault)), [false, false, true, false])
  assert.deepEqual(plain(s.subtitle.map(a => a.forced)), [false, true, false, false])
  assert.equal(s.audio.every(a => a.external === false), true)
})

test("mapStreams flags image-based subtitles the internal player cannot draw", () => {
  const s = A.mapStreams(akiraStreams)
  // pgs, pgs, vobsub, srt — only the last one is text, and only text renders
  // on Qt's ffmpeg backend.
  assert.deepEqual(plain(s.subtitle.map(a => a.image)), [true, true, true, false])
  assert.equal(s.video.every(v => v.image === false), true)
})

test("mapStreams labels a row from extendedDisplayTitle, so two dubs differ", () => {
  const s = A.mapStreams(akiraStreams)
  assert.equal(s.audio[2].label, "Nuovo doppiaggio (Italiano AC3 5.1)")
  assert.equal(s.audio[3].label, "Doppiaggio Storico (Italiano AC3 Stereo)")
  assert.notEqual(s.audio[2].label, s.audio[3].label)
})

test("streamLabel falls back through displayTitle to language and codec", () => {
  assert.equal(A.streamLabel({ extendedDisplayTitle: "", displayTitle: "English" }), "English")
  assert.equal(A.streamLabel({ language: "Deutsch", codec: "eac3" }), "Deutsch · EAC3")
  assert.equal(A.streamLabel({ languageTag: "fr" }), "fr")
  assert.equal(A.streamLabel({ codec: "aac" }), "AAC")
  assert.equal(A.streamLabel({}), "Track")
})

test("mapStreams tolerates shows, seasons and junk without throwing", () => {
  const empty = { partId: "", video: [], audio: [], subtitle: [] }
  // A show carries no Media at all.
  assert.deepEqual(plain(A.mapStreams({ MediaContainer: { Metadata: [{ type: "show" }] } })), empty)
  assert.deepEqual(plain(A.mapStreams({ MediaContainer: {} })), empty)
  assert.deepEqual(plain(A.mapStreams({})), empty)
  assert.deepEqual(plain(A.mapStreams(null)), empty)
  assert.deepEqual(plain(A.mapStreams({ MediaContainer: { Metadata: [{ Media: [{ Part: [{ id: 7 }] }] }] } })),
    { partId: "7", video: [], audio: [], subtitle: [] })
  // A null hole in the array, and a streamType nobody has ever heard of.
  const odd = { MediaContainer: { Metadata: [{ Media: [{ Part: [{ id: 9, Stream: [
    null, { id: 1, streamType: 4 }, { id: 2, streamType: 2 }
  ] }] }] }] } }
  const s = A.mapStreams(odd)
  assert.equal(s.audio.length, 1)
  assert.equal(s.audio[0].ordinal, 0)
})

test("mapStreams gives a sidecar stream ordinal -1 and skips it in the count", () => {
  // Defensive: no stream carrying a `key` was found on the live server, so
  // this pins the intent rather than an observed response.
  const withSidecar = { MediaContainer: { Metadata: [{ Media: [{ Part: [{ id: 3, Stream: [
    { id: 10, streamType: 3, codec: "srt", displayTitle: "English" },
    { id: 11, streamType: 3, codec: "srt", displayTitle: "Sidecar",
      key: "/library/streams/11" },
    { id: 12, streamType: 3, codec: "ass", displayTitle: "Japanese" }
  ] }] }] }] } }
  const s = A.mapStreams(withSidecar)
  assert.deepEqual(plain(s.subtitle.map(x => x.ordinal)), [0, -1, 1])
  assert.deepEqual(plain(s.subtitle.map(x => x.external)), [false, true, false])
})

test("selectedStreamId returns the flagged id, or empty when nothing is set", () => {
  const s = A.mapStreams(akiraStreams)
  assert.equal(A.selectedStreamId(s.audio), "1515")
  assert.equal(A.selectedStreamId(s.subtitle), "1519")
  assert.equal(A.selectedStreamId(s.video), "")
  assert.equal(A.selectedStreamId([]), "")
  assert.equal(A.selectedStreamId(null), "")
})

test("partSelectionUrl sends allParts and treats 0 as an explicit 'no subtitles'", () => {
  assert.equal(A.partSelectionUrl("http://s:32400", 524, "1516", "1518"),
    "http://s:32400/library/parts/524?audioStreamID=1516&subtitleStreamID=1518&allParts=1")
  // The two params are independent: an audio-only PUT leaves
  // the subtitle selection alone rather than clearing it.
  assert.equal(A.partSelectionUrl("http://s:32400", 524, "1517", ""),
    "http://s:32400/library/parts/524?audioStreamID=1517&allParts=1")
  // ...and 0 must survive as a real value, not be dropped as falsy.
  assert.equal(A.partSelectionUrl("http://s:32400", 524, "", 0),
    "http://s:32400/library/parts/524?subtitleStreamID=0&allParts=1")
  assert.equal(A.partSelectionUrl("http://s:32400", 524, null, null),
    "http://s:32400/library/parts/524?allParts=1")
})
