#!/usr/bin/env bash
# Package build/CCUBar.app into a drag-and-drop .dmg for GitHub Releases.
#
# The .dmg is a release artifact, not a repo artifact — it is gitignored. The
# committed prebuilt bundle stays CCUBar.app / CCUBar.app.zip under build/.
#
# Note this does nothing for Gatekeeper: the app is ad-hoc signed, so first
# launch still needs the right-click-Open dance. Only Developer ID signing plus
# notarization removes that. See DISTRIBUTION.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/build/CCUBar.app"
DMG="$ROOT_DIR/build/CCUBar.dmg"
VOL_NAME="CCU Bar"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run ./Scripts/build_app.sh first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")"

# Stage the disk image contents: the app plus a symlink to /Applications, so the
# mounted volume reads as "drag this onto that".
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "[1/3] Staging $VERSION"
ditto "$APP" "$STAGE/CCUBar.app"
ln -s /Applications "$STAGE/Applications"

echo "[2/3] Building $DMG"
rm -f "$DMG"
# UDZO = zlib-compressed, read-only. srcfolder builds the filesystem for us, so
# no attach/detach cycle is needed.
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "[3/3] Verifying"
hdiutil verify "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "Built: $DMG ($SIZE, version $VERSION)"
