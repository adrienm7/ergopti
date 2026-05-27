#!/bin/zsh
# apps/App Cloner.app/Contents/Resources/make_icon.sh
# Builds AppIcon.icns from AppIcon.svg.
# Invoked automatically by Contents/MacOS/AppCloner when the .icns is missing
# or older than the SVG — the bundle is fully self-contained, no Hammerspoon
# startup hook required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$SCRIPT_DIR/AppIcon.svg"
ICNS="$SCRIPT_DIR/AppIcon.icns"

[[ ! -f "$SVG" ]] && { echo "Erreur : $SVG introuvable." >&2; exit 1; }

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner_icon.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT

qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$SVG" >/dev/null 2>&1 || true
PNG="$(ls -S "$TMPDIR_WORK"/*.png 2>/dev/null | head -n1 || true)"
[[ -z "$PNG" ]] && { echo "Erreur : qlmanage n'a produit aucun PNG." >&2; exit 1; }

ICONSET="$TMPDIR_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16   16   "$PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1
sips -z 32   32   "$PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1
sips -z 32   32   "$PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1
sips -z 64   64   "$PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1
sips -z 128  128  "$PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1
sips -z 256  256  "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
sips -z 256  256  "$PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1
sips -z 512  512  "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
sips -z 512  512  "$PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1
cp "$PNG"          "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"

BUNDLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Force Finder/Dock to drop their cached icon for this bundle. Without these
# steps, even after regenerating AppIcon.icns, Finder keeps showing the old
# icon (cached by inode + bundle id). Sequence:
#   1. Re-touch the bundle so its mtime changes → invalidates per-bundle
#      icon cache entries
#   2. Force-delete any per-app icon stored in the user's icon services
#      cache for this specific bundle path
#   3. Re-register with LaunchServices so it re-reads CFBundleIconFile
#   4. killall Dock + Finder so they reload icons from disk
touch "$BUNDLE_DIR"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$BUNDLE_DIR" >/dev/null 2>&1 || true
"$LSR" -f -r "$BUNDLE_DIR" >/dev/null 2>&1 || true
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "Icône générée : $ICNS"
