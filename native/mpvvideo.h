/*
 * MpvVideo — a minimal libmpv-backed video item for the Plex Mini panel.
 *
 * SPDX-License-Identifier: MIT
 *
 * Why this exists: QtMultimedia's sink does no HDR tone mapping (4K DoVi/HDR10
 * comes out with crushed blacks and clipped highlights) and frequently falls
 * back to software decode on NVIDIA. libmpv's renderer does both properly.
 *
 * Why MpvQt rather than raw libmpv: MpvQt (KDE, the foundation under Haruna)
 * already owns the hard part — creating the mpv_render_context on the Qt render
 * thread, driving mpv's event loop off the GUI thread, and tearing both down in
 * the right order. We only add the thin property/command surface the panel needs.
 *
 * Deliberately minimal: every member here maps to something PlexPanel.qml
 * already drives through the external-mpv IPC backend. Nothing speculative.
 */

#pragma once

#include <MpvAbstractItem>

#include <QStringList>
#include <QtQml/qqmlregistration.h>

class MpvVideo : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT

    // All five of these are mpv properties observed via observeProperty() and
    // cached here, so QML bindings update from mpv's own event stream instead of
    // the 250 ms socat poll the IPC backend needs.
    Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)
    Q_PROPERTY(double timePos READ timePos NOTIFY timePosChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(int volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)

    // Security win over the external-mpv backend: that one passes
    // "--http-header-fields=X-Plex-Token: ..." in argv, where the token is
    // world-readable in /proc/PID/cmdline for the life of the process. Here the
    // header is set as an mpv property inside our own address space — it never
    // touches a command line, an environment variable, or a log.
    Q_PROPERTY(QStringList httpHeaders READ httpHeaders WRITE setHttpHeaders NOTIFY httpHeadersChanged)

public:
    explicit MpvVideo(QQuickItem *parent = nullptr);

    // ---- playback ----
    // startSeconds is the Plex resume point; 0 starts at the head.
    Q_INVOKABLE void loadUrl(const QString &url, double startSeconds = 0.0);
    Q_INVOKABLE void stop();

    // ---- seeking ----
    Q_INVOKABLE void seekAbsolute(double seconds);
    Q_INVOKABLE void seekRelative(double seconds);

    // ---- tracks ----
    // Ordinals are 1-based, matching mpv's aid/sid numbering. Anything < 1
    // selects "no", which is how the panel's picker spells "none" already.
    Q_INVOKABLE void setAudioTrack(int ordinal);
    Q_INVOKABLE void setSubtitleTrack(int ordinal);

    bool paused() const { return m_paused; }
    void setPaused(bool value);
    double timePos() const { return m_timePos; }
    double duration() const { return m_duration; }
    int volume() const { return m_volume; }
    void setVolume(int value);
    bool muted() const { return m_muted; }
    void setMuted(bool value);
    QStringList httpHeaders() const { return m_httpHeaders; }
    void setHttpHeaders(const QStringList &headers);

Q_SIGNALS:
    void pausedChanged();
    void timePosChanged();
    void durationChanged();
    void volumeChanged();
    void mutedChanged();
    void httpHeadersChanged();

    void fileLoaded();
    void endReached();
    void playbackFailed(const QString &reason);

private:
    void onPropertyChanged(const QString &name, const QVariant &value);
    void onEndFile(const QString &reason);

    bool m_paused{false};
    double m_timePos{0.0};
    double m_duration{0.0};
    int m_volume{100};
    bool m_muted{false};
    QStringList m_httpHeaders;
};
