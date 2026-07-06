#!/usr/bin/env bash
#
# Rebuild the Ghostty Sidebar fork and (re)install it to /Applications.
#
# Builds from source, quits the running app, replaces the installed copy,
# re-registers it with LaunchServices (so Spotlight keeps finding it), then
# launches the fresh build. Run it from anywhere:
#
#   ./rebuild-ghostty.sh
#
set -euo pipefail

# Repo root = the directory this script lives in.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Ghostty Sidebar"
INSTALLED_APP="/Applications/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

cd "$REPO_DIR"

echo "==> Building (zig build)…"
zig build

echo "==> Quitting ${APP_NAME} if running…"
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true

echo "==> Installing to ${INSTALLED_APP}…"
rm -rf "$INSTALLED_APP"
cp -R "$REPO_DIR/zig-out/Ghostty.app" "$INSTALLED_APP"

echo "==> Registering with LaunchServices (for Spotlight)…"
"$LSREGISTER" -f "$INSTALLED_APP"

echo "==> Launching…"
open "$INSTALLED_APP"

echo "Done. Search Spotlight for \"${APP_NAME}\"."
