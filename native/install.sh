#!/usr/bin/env bash
# Builds and installs the PlexMpv native video module (libmpv via MpvQt).
# Needs sudo for the final install into /usr/lib/qt6/qml/.
set -euo pipefail
cd "$(dirname "$0")"

missing=()
pacman -Q mpvqt >/dev/null 2>&1 || missing+=(mpvqt)
command -v cmake >/dev/null 2>&1 || missing+=(cmake)
if ((${#missing[@]})); then
  echo ":: installing build deps: ${missing[*]}"
  omarchy pkg add "${missing[@]}"
fi

cmake -B build
cmake --build build
echo ":: installing to /usr/lib/qt6/qml/PlexMpv (sudo)"
sudo cmake --install build
echo ":: done — run 'omarchy restart shell' and the player upgrades itself"
