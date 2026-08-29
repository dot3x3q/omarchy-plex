/*
 * SPDX-License-Identifier: MIT
 * See mpvvideo.h for why this module exists.
 */

#include "mpvvideo.h"

#include <MpvController>

#include <QVariant>
#include <algorithm>

MpvVideo::MpvVideo(QQuickItem *parent)
    : MpvAbstractItem(parent)
{
    // MpvQt runs the mpv event loop on its own thread and re-emits events on
    // ours, so every signal below arrives on the GUI thread. Property *access*
    // must not block that thread: setProperty()/command() are the async forms
    // (they queue onto the mpv thread), and reads come from the observed cache
    // below rather than getProperty(), which round-trips and blocks.
    // Qt::QueuedConnection explicitly, as Haruna does: the emitter lives on the
    // mpv thread, and a queued connection guarantees these run on ours even if
    // the affinity of either object is changed later.
    connect(mpvController(), &MpvController::propertyChanged,
            this, &MpvVideo::onPropertyChanged, Qt::QueuedConnection);
    connect(mpvController(), &MpvController::fileLoaded,
            this, &MpvVideo::fileLoaded, Qt::QueuedConnection);
    connect(mpvController(), &MpvController::endFile,
            this, &MpvVideo::onEndFile, Qt::QueuedConnection);

    // ---- observed properties ----
    // Each one feeds a Q_PROPERTY NOTIFY, so QML bindings track mpv directly.
    observeProperty(QStringLiteral("pause"), MPV_FORMAT_FLAG);
    observeProperty(QStringLiteral("time-pos"), MPV_FORMAT_DOUBLE);
    observeProperty(QStringLiteral("duration"), MPV_FORMAT_DOUBLE);
    observeProperty(QStringLiteral("volume"), MPV_FORMAT_DOUBLE);
    observeProperty(QStringLiteral("mute"), MPV_FORMAT_FLAG);

    // ---- init options ----
    // vo is NOT set here: MpvQt creates the mpv_render_context itself, which
    // requires vo=libmpv, and it sets that during its own init. Overriding it
    // would break rendering.
    //
    // Hardware decode. auto-safe rather than auto: it only picks hwdec methods
    // that are known-good with the libmpv render API (nvdec/vaapi copy-back
    // included), which is the whole point of moving off QtMultimedia on NVIDIA.
    setProperty(QStringLiteral("hwdec"), QStringLiteral("auto-safe"));

    // Do not linger on the last frame at EOF — the panel wants a clean
    // endReached() so it can post the scrobble and leave theater.
    setProperty(QStringLiteral("keep-open"), QStringLiteral("no"));

    // Keep the core alive between files. Without this, keep-open=no would let
    // mpv shut down after the first EOF and the item would be dead for reuse.
    setProperty(QStringLiteral("idle"), QStringLiteral("yes"));

    // The panel's volume model is one 0-200 number (>100 is real gain for quiet
    // film mixes). Qt caps its own sink at 1.0; mpv does not, once told to.
    setProperty(QStringLiteral("volume-max"), 200);

    // Security posture, carried over from the external-mpv backend: no user
    // config or scripts, and no ytdl/youtube-dl extractor spawning on a URL we
    // did not construct ourselves.
    //
    // Caveat worth knowing: MpvQt's own init() runs before this ctor body and
    // does `include=$XDG_CONFIG_HOME/mpvqt/mpvqt.conf`. An explicit include is
    // not suppressed by config=no, so a user file at that path still applies.
    // That is MpvQt's documented extension point, not a hole we opened.
    setProperty(QStringLiteral("config"), QStringLiteral("no"));
    setProperty(QStringLiteral("ytdl"), QStringLiteral("no"));

    // Plex serves seekable HTTP; without this an unseekable-looking stream
    // would make the scrubber inert.
    setProperty(QStringLiteral("force-seekable"), QStringLiteral("yes"));
}

void MpvVideo::loadUrl(const QString &url, double startSeconds)
{
    if (url.isEmpty()) {
        Q_EMIT playbackFailed(QStringLiteral("empty url"));
        return;
    }

    // The resume point goes in as a property rather than as a loadfile option.
    // Why: mpv 0.38 inserted an <index> argument into loadfile
    // (`loadfile <url> [<flags> [<index> [<options>]]]`), so the once-correct
    // three-argument `loadfile url replace start=X` now silently means
    // something else. Setting `start` first and calling bare loadfile is what
    // Haruna and mpvqt's own example do, and it cannot rot across mpv versions.
    //
    // Ordering is safe without a blocking call: setProperty() and command() are
    // both queued to the same MpvController on the same thread, so they arrive
    // in the order issued.
    setProperty(QStringLiteral("start"),
                QString::number(startSeconds > 0.0 ? startSeconds : 0.0, 'f', 3));
    command({QStringLiteral("loadfile"), url});
}

void MpvVideo::stop()
{
    // "stop" unloads the file but leaves the core idle and reusable, unlike
    // "quit". The resulting end-file reason is "stop", which onEndFile ignores
    // — a user-initiated stop is not an EOF and not a failure.
    command({QStringLiteral("stop")});
}

void MpvVideo::seekAbsolute(double seconds)
{
    command({QStringLiteral("seek"), QString::number(seconds, 'f', 3),
             QStringLiteral("absolute")});
}

void MpvVideo::seekRelative(double seconds)
{
    command({QStringLiteral("seek"), QString::number(seconds, 'f', 3),
             QStringLiteral("relative")});
}

void MpvVideo::setAudioTrack(int ordinal)
{
    setProperty(QStringLiteral("aid"),
                ordinal >= 1 ? QVariant(ordinal) : QVariant(QStringLiteral("no")));
}

void MpvVideo::setSubtitleTrack(int ordinal)
{
    setProperty(QStringLiteral("sid"),
                ordinal >= 1 ? QVariant(ordinal) : QVariant(QStringLiteral("no")));
}

void MpvVideo::setPaused(bool value)
{
    // No local write to m_paused: the observed property is the single source of
    // truth, so the binding only flips once mpv has actually paused. Same
    // pattern for volume and mute below.
    setProperty(QStringLiteral("pause"), value);
}

void MpvVideo::setVolume(int value)
{
    setProperty(QStringLiteral("volume"), std::clamp(value, 0, 200));
}

void MpvVideo::setMuted(bool value)
{
    setProperty(QStringLiteral("mute"), value);
}

void MpvVideo::setHttpHeaders(const QStringList &headers)
{
    if (m_httpHeaders == headers)
        return;
    m_httpHeaders = headers;
    // Must be set BEFORE loadUrl(): mpv reads http-header-fields when it opens
    // the stream, not continuously.
    setProperty(QStringLiteral("http-header-fields"), headers);
    Q_EMIT httpHeadersChanged();
}

void MpvVideo::onPropertyChanged(const QString &name, const QVariant &value)
{
    // mpv sends a property change with an invalid/none value when the property
    // is unavailable (e.g. time-pos while nothing is loaded); ignore those
    // rather than publishing a spurious 0 that would jump the scrubber.
    if (!value.isValid())
        return;

    if (name == QLatin1String("pause")) {
        const bool v = value.toBool();
        if (v != m_paused) { m_paused = v; Q_EMIT pausedChanged(); }
    } else if (name == QLatin1String("time-pos")) {
        const double v = value.toDouble();
        if (!qFuzzyCompare(v + 1.0, m_timePos + 1.0)) { m_timePos = v; Q_EMIT timePosChanged(); }
    } else if (name == QLatin1String("duration")) {
        const double v = value.toDouble();
        if (!qFuzzyCompare(v + 1.0, m_duration + 1.0)) { m_duration = v; Q_EMIT durationChanged(); }
    } else if (name == QLatin1String("volume")) {
        const int v = qRound(value.toDouble());
        if (v != m_volume) { m_volume = v; Q_EMIT volumeChanged(); }
    } else if (name == QLatin1String("mute")) {
        const bool v = value.toBool();
        if (v != m_muted) { m_muted = v; Q_EMIT mutedChanged(); }
    }
}

void MpvVideo::onEndFile(const QString &reason)
{
    // mpv's end-file reasons: eof, stop, quit, error, redirect, unknown.
    // Only "eof" is a finished item; only "error" is a failure the panel should
    // fall back on (it retries via server transcode). "stop"/"quit" are ours.
    if (reason == QLatin1String("eof")) {
        Q_EMIT endReached();
    } else if (reason == QLatin1String("error")) {
        Q_EMIT playbackFailed(QStringLiteral("mpv could not play this stream"));
    }
}
