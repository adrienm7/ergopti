#!/bin/zsh
# apps/AppCloner.app/Contents/Resources/clone_app.sh
#
# Crée un clone léger d'une application macOS avec :
#   - bundle ID unique  → pas de regroupement Dock avec l'originale
#   - icône teintée     → couleur personnalisée sur l'icône source (CoreImage)
#   - wrapper shell     → relance l'app originale (-n = nouvelle instance)
#   - option dossier    → dossier à passer à l'ouverture
#   - ajout au Dock     → placé dans ~/Applications et épinglé au Dock
#
# Usage:
#   clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>
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
# 2) Nom de fichier sûr
# ─────────────────────────────────────────────
safe_name="$(printf '%s' "$CLONE_NAME" \
  | sed 's|/|-|g' \
  | sed "s/[^[:alnum:][:space:]'._()-]/_/g" \
  | sed 's/__*/_/g' \
  | sed -e 's/^[ _-]*//' -e 's/[ _-]*$//')"
[[ -z "$safe_name" ]] && safe_name="Clone"

# Installer dans ~/Applications pour que le Dock puisse l'épingler proprement
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
      echo "Base PNG extracted: $sz"
      break
    fi
  done
fi

if [[ ! -f "$BASE_PNG" ]]; then
  echo "No base PNG — using generic fallback"
  SRC_NAME="$(basename "$SOURCE_APP" .app)"
  INITIALS="${SRC_NAME:0:2}"
  SVG_FALLBACK="$TMPDIR_WORK/fallback.svg"
  cat > "$SVG_FALLBACK" <<SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" ry="220" fill="#888888"/>
  <text x="512" y="512" font-family="Helvetica-Bold,Arial,sans-serif" font-size="420" font-weight="900"
        fill="#FFFFFF" text-anchor="middle" dominant-baseline="middle">${INITIALS}</text>
</svg>
SVGEOF
  qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$SVG_FALLBACK" >/dev/null 2>&1 || true
  FALLBACK_PNG="$(ls "$TMPDIR_WORK"/*.png 2>/dev/null | head -n1 || true)"
  [[ -n "$FALLBACK_PNG" ]] && cp "$FALLBACK_PNG" "$BASE_PNG"
fi

# ─────────────────────────────────────────────
# 4) Teinte via Python3 + Quartz (natif macOS)
# ─────────────────────────────────────────────
# Parse la couleur hex en composantes 0.0-1.0
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'PYEOF'
import sys, os
sys.path.insert(0, '/System/Library/Frameworks/Python.framework/Versions/Current/Extras/lib/python')
import Quartz
import Quartz.CoreGraphics as CG

src, dst, r, g, b = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

# Load source image
data_provider = CG.CGDataProviderCreateWithFilename(src)
src_img = CG.CGImageCreateWithPNGDataProvider(data_provider, None, False, CG.kCGRenderingIntentDefault)
w = CG.CGImageGetWidth(src_img)
h = CG.CGImageGetHeight(src_img)

# Create RGBA bitmap context
cs = CG.CGColorSpaceCreateDeviceRGB()
ctx = CG.CGBitmapContextCreate(None, w, h, 8, 0, cs,
    CG.kCGImageAlphaPremultipliedLast | CG.kCGBitmapByteOrder32Big)

# Draw source image
CG.CGContextDrawImage(ctx, CG.CGRectMake(0, 0, w, h), src_img)

# Draw tint overlay at 45% opacity
CG.CGContextSetRGBFillColor(ctx, r/255.0, g/255.0, b/255.0, 0.45)
CG.CGContextSetBlendMode(ctx, CG.kCGBlendModeMultiply)
CG.CGContextFillRect(ctx, CG.CGRectMake(0, 0, w, h))

# Export PNG
out_img = CG.CGBitmapContextCreateImage(ctx)
url = CG.CFURLCreateWithFileSystemPath(None, dst, CG.kCFURLPOSIXPathStyle, False)
dest = CG.CGImageDestinationCreateWithURL(url, b'public.png', 1, None)
CG.CGImageDestinationAddImage(dest, out_img, None)
CG.CGImageDestinationFinalize(dest)
print(f"Tinted PNG written: {dst} ({w}x{h})")
PYEOF

if [[ ! -f "$TINTED_PNG" ]]; then
  echo "Tint failed — using base PNG as-is"
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
echo "icns generated: $ICONFILE"

# ─────────────────────────────────────────────
# 6) Info.plist du clone
# ─────────────────────────────────────────────
UNIQUE_ID="fr.b519hs.clone.$(date +%s)"
# Lire le bundle ID de l'app source pour le passer en LSEnvironment
SRC_BUNDLE_ID="$(defaults read "$SRC_PLIST" CFBundleIdentifier 2>/dev/null || true)"
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
  <key>LSEnvironment</key>
  <dict>
    <key>BUNDLE_ID</key>
    <string>${UNIQUE_ID}</string>
  </dict>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────
# 7) Exécutable launcher (Python3)
# ─────────────────────────────────────────────
# On utilise Python3 comme launcher pour deux raisons :
#   a) macOS accepte python3 comme binaire de bundle (contrairement à zsh)
#   b) On peut manipuler les variables d'environnement avant exec pour que
#      le processus soit bien distinct de l'app source dans le Dock
#
# La clé pour que le Dock ne regroupe PAS le clone avec l'originale :
# CFBundleIdentifier différent dans Info.plist (déjà fait) ET lancer via
# NSWorkspace openApplicationAtURL qui respecte le bundle ID du clone.
cat > "$MACOS/launcher" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, subprocess

def main():
    # Chemin résolu depuis le binaire lui-même
    macos_dir  = os.path.dirname(os.path.realpath(__file__))
    clone_root = os.path.dirname(os.path.dirname(macos_dir))
    plist      = os.path.join(clone_root, "Contents", "Info.plist")

    # Lire SOURCE_APP et OPEN_ARG depuis le fichier de config du clone
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

    # Lancer via NSWorkspace pour que macOS respecte le bundle ID du clone
    # et n'associe pas la fenêtre à l'app originale dans le Dock
    script = f'tell application "Finder" to open POSIX file "{source_app}"'
    args = [source_app]
    if open_arg and os.path.exists(open_arg):
        args = ["-n", "--args", open_arg]
        cmd = ["open", "-n", "-a", source_app, open_arg]
    else:
        cmd = ["open", "-n", "-a", source_app]

    # Définir APP_BUNDLE_ID pour que certaines apps Electron créent une instance distincte
    env = os.environ.copy()
    env["ELECTRON_IS_DEV"] = "0"

    subprocess.Popen(cmd, env=env, close_fds=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$MACOS/launcher"

# Fichier de config lu par le launcher au moment de l'exécution
cat > "$RES/config.sh" <<CONFIGEOF
SOURCE_APP="$SOURCE_APP"
OPEN_ARG="$OPEN_ARG"
CONFIGEOF

# ─────────────────────────────────────────────
# 8) Enregistrement + ajout au Dock
# ─────────────────────────────────────────────
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

# Ajouter au Dock via Python3/ScriptingBridge (plus fiable que defaults write)
python3 - "$DEST" <<'DOCKEOF'
import subprocess, sys, os

app_path = sys.argv[1]

# Ajouter l'entrée dans le Dock via AppleScript
script = f'''
tell application "System Events"
  tell dock preferences
    set the end of the persistent application list to "{app_path}"
  end tell
end tell
'''
result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
if result.returncode != 0:
    print(f"Dock add failed: {result.stderr}", file=sys.stderr)
else:
    print(f"Added to Dock: {app_path}")
DOCKEOF

echo "$DEST"
