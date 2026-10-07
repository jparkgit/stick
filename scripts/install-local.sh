#!/usr/bin/env bash
# Build Stick.app from this checkout, install it to ~/Applications (replacing
# any existing copy), and relaunch it. Skips the zip/DMG, so the tracked
# dist/ downloads are left untouched.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${STICK_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/Stick.app"

"$ROOT_DIR/scripts/build-app.sh" --app-only

# Quit the running copy normally (so it saves its notes) before replacing it.
if pgrep -x Stick >/dev/null; then
  echo "Quitting running Stick..."
  osascript -e 'tell application id "com.jvalaj.stick" to quit' >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x Stick >/dev/null || break
    sleep 0.1
  done
  pkill -x Stick 2>/dev/null || true
fi

if pgrep -x StickyNotes >/dev/null; then
  echo "Note: a 'swift run' copy (StickyNotes) is still running and shares the same notes file. Quit it to avoid overwriting notes."
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$ROOT_DIR/dist/Stick.app" "$APP_PATH"
open "$APP_PATH"

echo "Installed and launched $APP_PATH"
if [[ "$INSTALL_DIR" != "/Applications" && -d "/Applications/Stick.app" ]]; then
  echo "Note: an older copy also exists at /Applications/Stick.app. Delete it so Spotlight/Launchpad open this one."
fi
