#!/usr/bin/env bash
# Build Resources/AppIcon.icns from an SF Symbol (default: gauge.with.dots.needle.67percent).
# Override by setting `SF_SYMBOL=<name>` before running this script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="$ROOT_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
ICNS_OUT="$RES_DIR/AppIcon.icns"
SYMBOL="${SF_SYMBOL:-gauge.with.dots.needle.67percent}"

mkdir -p "$RES_DIR" "$(dirname "$ICONSET_DIR")"

echo "[1/2] Rasterizing SF Symbol '$SYMBOL' to PNGs"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
swift "$ROOT_DIR/Scripts/generate_sf_symbol_icon.swift" "$SYMBOL" "$ICONSET_DIR"

echo "[2/2] Packing into $ICNS_OUT"
iconutil -c icns -o "$ICNS_OUT" "$ICONSET_DIR"

rm -rf "$ICONSET_DIR"
echo "Built: $ICNS_OUT"
