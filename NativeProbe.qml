import QtQuick
import PlexMpv 1.0

// Availability probe only: the import line above either resolves or fails the
// Loader that sources this file. The Item costs nothing — unlike instantiating
// MpvVideo, which spins up a whole idle libmpv core just to prove the module
// exists. The real players are created per-surface, on demand, in PlexPanel.
Item {}
