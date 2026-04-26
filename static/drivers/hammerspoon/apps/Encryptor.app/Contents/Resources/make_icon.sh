#!/bin/zsh
# apps/Encryptor.app/Contents/Resources/make_icon.sh
#
# Génère AppIcon.icns depuis AppIcon.svg et rafraîchit le cache d'icône macOS.
# À exécuter une fois après installation ou mise à jour du bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$SCRIPT_DIR/AppIcon.svg"
ICNS="$SCRIPT_DIR/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
  echo "Erreur : $SVG introuvable." >&2
  exit 1
fi

TMPDIR_WORK=$(mktemp -d "/tmp/encryptor_icon.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Rasteriser le SVG en PNG 1024×1024 via qlmanage
qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$SVG" >/dev/null 2>&1 || true
PNG="$(ls -S "$TMPDIR_WORK"/*.png 2>/dev/null | head -n1 || true)"
if [[ -z "$PNG" ]]; then
  echo "Erreur : qlmanage n'a produit aucun PNG." >&2
  exit 1
fi

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
cp "$PNG"         "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"

# Rafraîchir le cache d'icône du Dock
BUNDLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
touch "$BUNDLE_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$BUNDLE_DIR" >/dev/null 2>&1 || true

echo "Icône générée : $ICNS"
