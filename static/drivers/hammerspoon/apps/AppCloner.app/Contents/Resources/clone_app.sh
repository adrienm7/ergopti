#!/bin/zsh
# apps/AppCloner.app/Contents/Resources/clone_app.sh
#
# Crée un clone léger d'une application macOS.
# Usage: clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>
set -euo pipefail

SOURCE_APP="$1"
CLONE_NAME="$2"
COLOR_HEX="$3"
OPEN_ARG="$4"

LOG=/tmp/clone_app.log
exec >> "$LOG" 2>&1
echo "=== clone_app.sh $(date) ==="
echo "SOURCE=$SOURCE_APP  NAME=$CLONE_NAME  COLOR=$COLOR_HEX  ARG=$OPEN_ARG"


# ─────────────────────────────────────────────
# 1) Validation
# ─────────────────────────────────────────────
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Erreur : application source introuvable : $SOURCE_APP" >&2
  exit 1
fi


# ─────────────────────────────────────────────
# 2) Nom de fichier sûr — conserver les chars Unicode courants
# ─────────────────────────────────────────────
# On remplace seulement les chars vraiment interdits dans un nom de fichier macOS (:/)
safe_name="$(printf '%s' "$CLONE_NAME" | tr ':/' '-')"
safe_name="${safe_name## }"; safe_name="${safe_name%% }"
[[ -z "$safe_name" ]] && safe_name="Clone"

APPS_DIR="$HOME/Applications"
mkdir -p "$APPS_DIR"
DEST="$APPS_DIR/${safe_name}.app"
if [[ -e "$DEST" ]]; then
  DEST="$APPS_DIR/${safe_name}_$(date +%s).app"
fi
echo "DEST=$DEST"

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT


# ─────────────────────────────────────────────
# 3) Extraction de l'icône source → PNG
# ─────────────────────────────────────────────
SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_ICON_FILE="$(defaults read "$SRC_PLIST" CFBundleIconFile 2>/dev/null || true)"
[[ -n "$SRC_ICON_FILE" && "${SRC_ICON_FILE##*.}" != "icns" ]] && SRC_ICON_FILE="${SRC_ICON_FILE}.icns"

SRC_ICNS=""
if [[ -n "$SRC_ICON_FILE" ]]; then
  candidate="$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE"
  [[ -f "$candidate" ]] && SRC_ICNS="$candidate"
fi
if [[ -z "$SRC_ICNS" ]]; then
  SRC_ICNS="$(find "$SOURCE_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -n1 || true)"
fi
echo "SRC_ICNS=$SRC_ICNS"

BASE_PNG="$TMPDIR_WORK/base.png"
if [[ -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
  ICONSET_TMP="$TMPDIR_WORK/src.iconset"
  iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" 2>/dev/null || true
  for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256" "icon_128x128@2x"; do
    candidate="$ICONSET_TMP/${sz}.png"
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$BASE_PNG"
      echo "Base PNG: $sz"
      break
    fi
  done
fi

if [[ ! -f "$BASE_PNG" ]]; then
  echo "No base PNG — generic fallback"
  SRC_NAME="$(basename "$SOURCE_APP" .app)"
  cat > "$TMPDIR_WORK/fallback.svg" <<SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" ry="220" fill="#888888"/>
  <text x="512" y="512" font-family="Helvetica-Bold,Arial,sans-serif" font-size="420" font-weight="900"
        fill="#FFFFFF" text-anchor="middle" dominant-baseline="middle">${SRC_NAME:0:2}</text>
</svg>
SVGEOF
  qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$TMPDIR_WORK/fallback.svg" >/dev/null 2>&1 || true
  FALLBACK_PNG="$(ls "$TMPDIR_WORK"/*.png 2>/dev/null | head -n1 || true)"
  [[ -n "$FALLBACK_PNG" ]] && cp "$FALLBACK_PNG" "$BASE_PNG"
fi


# ─────────────────────────────────────────────
# 4) Teinte via osascript JXA (pas de compilation)
# ─────────────────────────────────────────────
# Blend mode "hue" : applique la teinte sur les zones colorées
# en préservant la luminosité → le blanc reste blanc, le noir reste noir.
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

osascript -l JavaScript - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'JSEOF'
ObjC.import('AppKit')
ObjC.import('CoreGraphics')

const args  = $.NSProcessInfo.processInfo.arguments
// args: [osascript, -, srcPath, dstPath, R, G, B]
const src   = args.objectAtIndex(2).js
const dst   = args.objectAtIndex(3).js
const r     = parseInt(args.objectAtIndex(4).js) / 255.0
const g     = parseInt(args.objectAtIndex(5).js) / 255.0
const b     = parseInt(args.objectAtIndex(6).js) / 255.0

const srcImg = $.NSImage.alloc.initWithContentsOfFile(src)
if (!srcImg.isNil()) {
  const size = srcImg.size
  const w = size.width, h = size.height

  const cs  = $.CGColorSpaceCreateDeviceRGB()
  const ctx = $.CGBitmapContextCreate(null, w, h, 8, 0, cs,
                $.kCGImageAlphaPremultipliedLast)

  // Dessiner l'image originale
  const cgImg = srcImg.CGImageForProposedRectContextHints(null, null, null)
  $.CGContextDrawImage(ctx, {origin:{x:0,y:0}, size:{width:w,height:h}}, cgImg)

  // Appliquer la teinte en mode "hue" : préserve luminosité et saturation d'origine
  // On utilise kCGBlendModeHue — seule la teinte (hue) change, pas la luminosité
  $.CGContextSetBlendMode(ctx, $.kCGBlendModeHue)
  // Saturation forte pour que la teinte soit visible sans écraser les zones neutres
  $.CGContextSetRGBFillColor(ctx, r, g, b, 0.8)
  $.CGContextFillRect(ctx, {origin:{x:0,y:0}, size:{width:w,height:h}})

  const outImg = $.CGBitmapContextCreateImage(ctx)
  const rep    = $.NSBitmapImageRep.alloc.initWithCGImage(outImg)
  const data   = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, {})
  data.writeToFileAtomically(dst, true)
  console.log(`Tinted ${w}x${h} → ${dst}`)
} else {
  console.error(`Cannot load ${src}`)
  $.exit(1)
}
JSEOF

if [[ ! -f "$TINTED_PNG" ]]; then
  echo "Tint failed — using base PNG"
  cp "$BASE_PNG" "$TINTED_PNG"
fi


# ─────────────────────────────────────────────
# 5) Génération du .icns
# ─────────────────────────────────────────────
ICONSET="$TMPDIR_WORK/clone.iconset"
mkdir -p "$ICONSET"
sips -z 16   16   "$TINTED_PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1 || true
sips -z 32   32   "$TINTED_PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1 || true
sips -z 32   32   "$TINTED_PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1 || true
sips -z 64   64   "$TINTED_PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1 || true
sips -z 128  128  "$TINTED_PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1 || true
sips -z 256  256  "$TINTED_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1 || true
sips -z 256  256  "$TINTED_PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1 || true
sips -z 512  512  "$TINTED_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1 || true
sips -z 512  512  "$TINTED_PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1 || true
cp "$TINTED_PNG"  "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true

ICONFILE="$RES/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICONFILE"
echo "icns: $ICONFILE"


# ─────────────────────────────────────────────
# 6) Info.plist du clone
# ─────────────────────────────────────────────
UNIQUE_ID="fr.b519hs.clone.$(date +%s)"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIdentifier</key>
  <string>${UNIQUE_ID}</string>
  <key>CFBundleName</key>
  <string>${safe_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${safe_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
</dict>
</plist>
PLIST


# ─────────────────────────────────────────────
# 7) Launcher Python3
# ─────────────────────────────────────────────
cat > "$MACOS/launcher" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, subprocess

macos_dir  = os.path.dirname(os.path.realpath(__file__))
clone_root = os.path.dirname(os.path.dirname(macos_dir))
config_path = os.path.join(clone_root, "Contents", "Resources", "config.sh")

source_app, open_arg = "", ""
if os.path.exists(config_path):
    with open(config_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("SOURCE_APP="):
                source_app = line[len("SOURCE_APP="):].strip('"')
            elif line.startswith("OPEN_ARG="):
                open_arg = line[len("OPEN_ARG="):].strip('"')

if not source_app or not os.path.isdir(source_app):
    sys.exit(1)

cmd = ["open", "-n", "-a", source_app]
if open_arg and os.path.exists(open_arg):
    cmd.append(open_arg)

subprocess.Popen(cmd, close_fds=True,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PYEOF
chmod +x "$MACOS/launcher"

# Config lue par le launcher
cat > "$RES/config.sh" <<CONFIGEOF
SOURCE_APP="$SOURCE_APP"
OPEN_ARG="$OPEN_ARG"
CONFIGEOF


# ─────────────────────────────────────────────
# 8) Enregistrement LaunchServices + Dock
# ─────────────────────────────────────────────
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

# Ajouter au Dock : modifier directement com.apple.dock.plist puis relancer le Dock
# C'est la méthode la plus fiable sans outil tiers
DOCK_PLIST="$HOME/Library/Preferences/com.apple.dock.plist"
python3 - "$DEST" "$DOCK_PLIST" <<'DOCKEOF'
import sys, plistlib, os, subprocess

app_path  = sys.argv[1]
plist_path = sys.argv[2]

with open(plist_path, 'rb') as f:
    dock = plistlib.load(f)

apps = dock.get('persistent-apps', [])

# Vérifier que l'app n'est pas déjà dans le Dock
for entry in apps:
    tile = entry.get('tile-data', {})
    fa   = tile.get('file-data', {})
    if fa.get('_CFURLString', '') == app_path or \
       fa.get('_CFURLString', '') == app_path + '/':
        print(f"Already in Dock: {app_path}")
        sys.exit(0)

# Construire l'entrée Dock
label = os.path.basename(app_path).removesuffix('.app')
entry = {
    'GUID': int.from_bytes(os.urandom(4), 'big'),
    'tile-data': {
        'file-data': {
            '_CFURLString': app_path + '/',
            '_CFURLStringType': 15,
        },
        'file-label': label,
        'file-type': 41,
        'parent-mod-date': 0,
    },
    'tile-type': 'file-tile',
}
apps.append(entry)
dock['persistent-apps'] = apps

with open(plist_path, 'wb') as f:
    plistlib.dump(dock, f)

subprocess.run(['killall', 'Dock'], check=False)
print(f"Added to Dock and restarted: {app_path}")
DOCKEOF

echo "$DEST"
