// The panel's shell scripts: config/state reads and writes, and the mpv IPC
// one-liners. Plain script, no module syntax — loaded by PlexPanel.qml as a
// JavaScript resource, and by tests/io-safety.test.mjs, which runs these exact
// strings under sh in a throwaway HOME rather than asserting on their text.
//
// Every script is FIXED source. Nothing is ever spliced into it: the caller
// passes paths and values as positional parameters —
//   ["sh", "-c", Io.someScript, "sh", dir, …]
// — so a directory name from $HOME / $XDG_*_HOME is data to the shell, never
// code, whatever quotes or `$(…)` it happens to contain. (These used to be
// built as "d='" + dir + "'; …", where a single quote in an environment
// variable would have ended the string and started a command.)
//
// The posture inside the scripts is upstream's and is preserved exactly:
//  - resolve the PARENT with cd -P, then require the leaf to be a real
//    directory (not a symlink), cd into it and re-check pwd -P, so every later
//    path is relative to a pinned inode and a swapped symlink cannot redirect;
//  - reads are one dd with O_NOFOLLOW (a symlinked file fails), O_NONBLOCK (a
//    FIFO cannot hang the shell) and a block size one byte over the parser's
//    ceiling, so oversize input is rejected by the caller's length check;
//  - writes go to a 0600 temp file under umask 077 in a 0700 directory and are
//    renamed into place, with a trap that removes the temp file on any failure.

// $1 = config directory. Prints at most 4097 bytes of config.json.
var readConfigScript =
  "d=$1; d=${d%/}; b=${d##*/}; "
  + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
  + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
  + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
  + "&& dd if=config.json iflag=nofollow,nonblock bs=4097 count=1 status=none 2>/dev/null || true"

// $1 = state directory. Prints at most 1025 bytes of window.json.
var readStateScript =
  "d=$1; d=${d%/}; b=${d##*/}; "
  + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 0; "
  + "[ -d \"$p/$b\" ] && [ ! -L \"$p/$b\" ] && cd -P -- \"$p/$b\" "
  + "&& [ \"$(pwd -P)\" = \"$p/$b\" ] "
  + "&& dd if=window.json iflag=nofollow,nonblock bs=1025 count=1 status=none 2>/dev/null || true"

// $1 = config directory. The secrets arrive on STDIN as one tab-separated
// line (server, token, backend) — never argv, never shell source.
var saveConfigScript =
  "IFS=$(printf '\t') read -r plex_server plex_token plex_backend || exit 1; "
  + "d=$1; d=${d%/}; b=${d##*/}; "
  + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
  + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
  + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
  + "&& umask 077 && t=.config.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
  + "&& printf '{\"server\":\"%s\",\"token\":\"%s\",\"backend\":\"%s\"}' "
  + "\"$plex_server\" \"$plex_token\" \"$plex_backend\" > \"$t\" "
  + "&& chmod 600 \"$t\" && mv -f -- \"$t\" config.json && trap - EXIT"

// $1 = state directory; $2..$7 = right, bottom, width, windowed, volume,
// quality. All are produced by the panel itself (integers and true/false), and
// they go into the JSON unquoted, as numbers and a boolean.
var saveStateScript =
  "d=$1; d=${d%/}; b=${d##*/}; "
  + "p=$(cd -P -- \"${d%/*}\" 2>/dev/null && pwd -P) || exit 1; "
  + "mkdir -p -- \"$p/$b\" && [ ! -L \"$p/$b\" ] && chmod 700 \"$p/$b\" "
  + "&& cd -P -- \"$p/$b\" && [ \"$(pwd -P)\" = \"$p/$b\" ] "
  + "&& umask 077 && t=.window.$$.tmp && trap 'rm -f -- \"$t\"' EXIT "
  + "&& printf '{\"right\":%s,\"bottom\":%s,\"width\":%s,\"windowed\":%s,\"volume\":%s,\"quality\":%s}' "
  + "\"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\""
  + " > \"$t\" && chmod 600 \"$t\" && mv -f -- \"$t\" window.json && trap - EXIT"

// $1 = mpv IPC socket. Asks a running mpv to quit; silent no-op when none is.
var mpvQuitScript =
  "test -S \"$1\" && echo '{\"command\":[\"quit\"]}' | socat - UNIX-CONNECT:\"$1\" >/dev/null 2>&1 || true"

// $1 = mpv IPC socket, $2 = newline-separated JSON-IPC commands. Replies go
// to stdout, one JSON object per line.
var mpvSendScript =
  "printf '%s\\n' \"$2\" | socat - UNIX-CONNECT:\"$1\""
