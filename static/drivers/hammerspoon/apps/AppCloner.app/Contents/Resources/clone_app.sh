#!/bin/zsh
# apps/AppCloner.app/Contents/Resources/clone_app.sh
# Usage: clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>

LOG=/tmp/clone_app.log
exec >> "$LOG" 2>&1

set -euo pipefail

SOURCE_APP="${1:-}"
CLONE_NAME="${2:-}"
COLOR_HEX="${3:-}"
OPEN_ARG="${4:-}"

echo "=== $(date) SOURCE=$SOURCE_APP NAME=$CLONE_NAME COLOR=$COLOR_HEX ARG=$OPEN_ARG ==="

[[ -z "$SOURCE_APP" ]] && { echo "Erreur : SOURCE_APP manquant"; exit 1; }
[[ ! -d "$SOURCE_APP" ]] && { echo "Erreur : source introuvable : $SOURCE_APP"; exit 1; }


# ── 1) Nom sûr ──────────────────────────────────────────────────────────────
safe_name="$(printf '%s' "$CLONE_NAME" | tr ':/' '-' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ -z "$safe_name" ]] && safe_name="Clone"

APPS_DIR="$HOME/Applications"
mkdir -p "$APPS_DIR"
DEST="$APPS_DIR/${safe_name}.app"
[[ -e "$DEST" ]] && DEST="$APPS_DIR/${safe_name}_$(date +%s).app"
echo "DEST=$DEST"

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT


# ── 2) Extraction icône source → PNG ────────────────────────────────────────
SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_ICON_FILE="$(defaults read "$SRC_PLIST" CFBundleIconFile 2>/dev/null || true)"
[[ -n "$SRC_ICON_FILE" && "${SRC_ICON_FILE##*.}" != "icns" ]] && SRC_ICON_FILE="${SRC_ICON_FILE}.icns"

SRC_ICNS=""
[[ -n "$SRC_ICON_FILE" && -f "$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE" ]] \
  && SRC_ICNS="$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE"
[[ -z "$SRC_ICNS" ]] \
  && SRC_ICNS="$(find "$SOURCE_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -n1 || true)"
echo "SRC_ICNS=$SRC_ICNS"

BASE_PNG="$TMPDIR_WORK/base.png"
if [[ -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
  ICONSET_TMP="$TMPDIR_WORK/src.iconset"
  iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" 2>/dev/null || true
  for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256"; do
    [[ -f "$ICONSET_TMP/${sz}.png" ]] && cp "$ICONSET_TMP/${sz}.png" "$BASE_PNG" && echo "PNG: $sz" && break
  done
fi
if [[ ! -f "$BASE_PNG" ]]; then
  echo "Fallback générique"
  SRC_INIT="${$(basename "$SOURCE_APP" .app):0:2}"
  cat > "$TMPDIR_WORK/fb.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" fill="#888"/>
  <text x="512" y="580" font-family="Helvetica-Bold" font-size="480" font-weight="900"
        fill="#FFF" text-anchor="middle">${SRC_INIT}</text>
</svg>
SVG
  qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$TMPDIR_WORK/fb.svg" >/dev/null 2>&1 || true
  cp "$(ls "$TMPDIR_WORK"/*.png 2>/dev/null | head -1)" "$BASE_PNG" 2>/dev/null || true
fi


# ── 3) Teinte via Core Image (Python + osascript) ───────────────────────────
# CIHueAdjust tourne la roue chromatique d'un angle relatif en radians.
# On calcule la rotation nécessaire pour amener la teinte dominante de l'icône
# vers la couleur cible. Les zones neutres (blanc/noir/gris) ne sont pas affectées.
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

# Passer src/dst/couleur cible à Python qui écrit le script AppleScript dans
# un fichier temporaire pour éviter tout problème d'encodage ou de continuation ¬
python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'TINTEOF'
import sys, subprocess, os, tempfile, math, colorsys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
r_int, g_int, b_int = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

# Teinte cible en radians (0..2pi)
target_h, _, _ = colorsys.rgb_to_hsv(r_int/255, g_int/255, b_int/255)
target_rad = target_h * 2 * math.pi

# Lire le PNG et calculer la teinte dominante sans dépendance externe
def read_png_pixels(path):
    with open(path, "rb") as f:
        data = f.read()
    # Trouver les chunks IHDR et IDAT
    pos = 8  # skip PNG signature
    width = height = 0
    idat_chunks = []
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos+4])[0]
        chunk_type = data[pos+4:pos+8]
        chunk_data = data[pos+8:pos+8+length]
        if chunk_type == b"IHDR":
            width, height = struct.unpack(">II", chunk_data[:8])
            bit_depth = chunk_data[8]
            color_type = chunk_data[9]
            if bit_depth != 8 or color_type not in (2, 6):
                return None, 0, 0  # only support 8-bit RGB/RGBA
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break
        pos += 12 + length
    if not idat_chunks:
        return None, 0, 0
    raw = zlib.decompress(b"".join(idat_chunks))
    channels = 4 if color_type == 6 else 3
    stride = 1 + width * channels
    pixels = []
    for y in range(height):
        row_start = y * stride + 1
        for x in range(0, width * channels, channels):
            r = raw[row_start + x]
            g = raw[row_start + x + 1]
            b = raw[row_start + x + 2]
            a = raw[row_start + x + 3] if channels == 4 else 255
            pixels.append((r, g, b, a))
    return pixels, width, height

pixels, w, h = read_png_pixels(src)

sum_cos, sum_sin, total = 0.0, 0.0, 0.0
if pixels:
    step = max(1, len(pixels) // 4000)
    for i in range(0, len(pixels), step):
        pr, pg, pb, pa = pixels[i]
        if pa < 10:
            continue
        ph, ps, pv = colorsys.rgb_to_hsv(pr/255, pg/255, pb/255)
        if ps < 0.15:
            continue
        weight = ps * pv
        angle = ph * 2 * math.pi
        sum_cos += math.cos(angle) * weight
        sum_sin += math.sin(angle) * weight
        total += weight

if total > 0:
    src_rad = math.atan2(sum_sin / total, sum_cos / total)
    if src_rad < 0:
        src_rad += 2 * math.pi
else:
    src_rad = 0.0

# Rotation relative : amène la teinte source vers la cible
delta_rad = target_rad - src_rad
print(f"src_hue_rad={src_rad:.4f} target_hue_rad={target_rad:.4f} delta={delta_rad:.4f}", flush=True)

# Écrire le script AppleScript dans un fichier temporaire (évite les problèmes ¬ et encodage)
scpt = tempfile.NamedTemporaryFile(suffix=".applescript", mode="w", delete=False)
scpt.write(f'''use framework "Foundation"
use framework "AppKit"
use framework "CoreImage"
use scripting additions
set srcURL to current application's NSURL's fileURLWithPath:"{src}"
set dstURL to current application's NSURL's fileURLWithPath:"{dst}"
set hueAngle to {delta_rad} as real
set srcImg to current application's NSImage's alloc()'s initWithContentsOfURL:srcURL
set ciImg to current application's CIImage's imageWithData:(srcImg's TIFFRepresentation())
set hueFilter to current application's CIFilter's filterWithName:"CIHueAdjust"
hueFilter's setValue:ciImg forKey:"inputImage"
hueFilter's setValue:hueAngle forKey:"inputAngle"
set outCI to hueFilter's outputImage()
set ciCtx to current application's CIContext's context()
ciCtx's writePNGRepresentationOfImage:outCI toURL:dstURL format:23 colorSpace:(current application's CGColorSpaceCreateDeviceRGB()) options:(current application's NSDictionary's dictionary()) |error|:(missing value)
''')
scpt.close()

result = subprocess.run(["osascript", scpt.name], capture_output=True, text=True)
os.unlink(scpt.name)
if result.returncode != 0:
    print(f"osascript error: {result.stderr.strip()}", flush=True)
    sys.exit(1)
print("tint OK", flush=True)
TINTEOF

[[ ! -f "$TINTED_PNG" ]] && { echo "Teinte échouée — copie base PNG"; cp "$BASE_PNG" "$TINTED_PNG"; }


# ── 4) Génération .icns ─────────────────────────────────────────────────────
ICONSET="$TMPDIR_WORK/clone.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512"; do
  sz="${spec%%:*}"; name="${spec##*:}"
  sips -z "$sz" "$sz" "$TINTED_PNG" --out "$ICONSET/${name}.png" >/dev/null 2>&1 || true
done
cp "$TINTED_PNG" "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
echo "icns OK"


# ── 5) Info.plist ────────────────────────────────────────────────────────────
UNIQUE_ID="fr.b519hs.clone.$(date +%s)"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIdentifier</key><string>${UNIQUE_ID}</string>
  <key>CFBundleName</key><string>${safe_name}</string>
  <key>CFBundleDisplayName</key><string>${safe_name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1.0</string>
</dict>
</plist>
PLIST


# ── 6) Launcher ──────────────────────────────────────────────────────────────
cat > "$MACOS/launcher" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, subprocess

macos_dir   = os.path.dirname(os.path.realpath(__file__))
clone_root  = os.path.dirname(os.path.dirname(macos_dir))
config_path = os.path.join(clone_root, "Contents", "Resources", "config.sh")

source_app, open_arg = "", ""
if os.path.exists(config_path):
    for line in open(config_path):
        line = line.strip()
        if line.startswith("SOURCE_APP="):
            source_app = line[11:].strip('"')
        elif line.startswith("OPEN_ARG="):
            open_arg = line[9:].strip('"')

if not source_app or not os.path.isdir(source_app):
    sys.exit(1)

cmd = ["open", "-n", "-a", source_app]
if open_arg and os.path.exists(open_arg):
    cmd.append(open_arg)

subprocess.Popen(cmd, close_fds=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PYEOF
chmod +x "$MACOS/launcher"

cat > "$RES/config.sh" <<CONF
SOURCE_APP="$SOURCE_APP"
OPEN_ARG="$OPEN_ARG"
CONF


# ── 7) Dock ──────────────────────────────────────────────────────────────────
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

# Édition directe du plist Dock — méthode fiable sans outil tiers
python3 - "$DEST" <<'DOCKEOF'
import sys, plistlib, os, subprocess, time

app_path   = sys.argv[1]
plist_path = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")

with open(plist_path, 'rb') as f:
    dock = plistlib.load(f)

apps = dock.get('persistent-apps', [])
url  = app_path.rstrip('/') + '/'

# Ne pas dupliquer
for e in apps:
    if e.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '') == url:
        print("Déjà dans le Dock")
        sys.exit(0)

label = os.path.basename(app_path).removesuffix('.app')
apps.append({
    'GUID': int.from_bytes(os.urandom(4), 'big'),
    'tile-data': {
        'file-data': {'_CFURLString': url, '_CFURLStringType': 15},
        'file-label': label,
        'file-type': 41,
        'parent-mod-date': 0,
    },
    'tile-type': 'file-tile',
})
dock['persistent-apps'] = apps

with open(plist_path, 'wb') as f:
    plistlib.dump(dock, f)

subprocess.run(['killall', 'Dock'], check=False)
print(f"Ajouté au Dock : {app_path}")
DOCKEOF

echo "$DEST"
