#!/usr/bin/env bash
# Install or update the screenRIG Plasma widget from this checkout.
#   ./install.sh               install or update the widget
#   ./install.sh --uninstall   undo its changes (teardown) and remove it
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
id=ai.screenrig.plasma
installed="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$id"

if [[ ${1:-} == --uninstall ]]; then
  if [[ -x $installed/contents/bin/screenrig-kde ]]; then
    "$installed/contents/bin/screenrig-kde" teardown || true
  fi
  kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1 || true
  echo "Removed $id. Remove the widget from your panel if it is still there."
  exit 0
fi

if [[ -d $installed ]]; then
  kpackagetool6 -t Plasma/Applet -u "$src/package"
else
  kpackagetool6 -t Plasma/Applet -i "$src/package"
fi
echo "Installed $id. Right-click the panel, Add Widgets, and drag screenRIG onto it."
echo "A running Plasma keeps the copy it loaded: log out and in, or run: systemctl --user restart plasma-plasmashell"
