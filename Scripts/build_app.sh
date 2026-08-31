#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCH_FLAGS=()
case "$(uname -m)" in
    arm64) ARCH_FLAGS+=("--arch" "arm64") ;;
    x86_64) ARCH_FLAGS+=("--arch" "x86_64") ;;
    *) ;;
esac

echo "[1/4] swift build -c release ${ARCH_FLAGS[*]}"
swift build -c release "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c release --show-bin-path "${ARCH_FLAGS[@]}")"
APP="$ROOT_DIR/build/CCUBar.app"

# Clean up legacy bundle name if present.
rm -rf "$ROOT_DIR/build/CCBar.app"

echo "[2/4] Assembling bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/CCUBar" "$APP/Contents/MacOS/CCUBar"
chmod +x "$APP/Contents/MacOS/CCUBar"

# Build the app icon on demand if it hasn't been generated yet.
if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    "$ROOT_DIR/Scripts/generate_app_icon.sh"
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the Python bridge (ensures auto-spawn works from Applications/).
if [[ -d "$ROOT_DIR/bridge" ]]; then
    rm -rf "$APP/Contents/Resources/bridge"
    mkdir -p "$APP/Contents/Resources/bridge"
    for f in claude_usage_scraper.py claude_token_stats.py requirements.txt run.sh stop.sh \
             statusline-custom.sh refresh_keychain.sh token.ini.example README.md LICENSE; do
        if [[ -f "$ROOT_DIR/bridge/$f" ]]; then
            cp "$ROOT_DIR/bridge/$f" "$APP/Contents/Resources/bridge/$f"
        fi
    done
    chmod +x "$APP/Contents/Resources/bridge/"*.sh 2>/dev/null || true
fi

VERSION="$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || echo "0.1.0")"
echo "[3/4] Writing Info.plist (version $VERSION)"
sed "s/__VERSION__/${VERSION}/g" "$ROOT_DIR/Scripts/Info.plist.template" > "$APP/Contents/Info.plist"

echo "[4/4] Ad-hoc signing"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(codesign skipped)"

echo "Built: $APP"
