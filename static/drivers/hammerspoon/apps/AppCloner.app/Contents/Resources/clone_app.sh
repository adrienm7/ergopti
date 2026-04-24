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


# ── 3) Teinte — rotation HSV pixel par pixel (Python stdlib pur) ─────────────
# Pas d'AppleScript ni de dépendance externe. On lit/écrit le PNG via struct+zlib,
# on tourne la teinte de chaque pixel coloré vers la cible, on préserve blanc/noir.
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'TINTEOF'
import sys, math, colorsys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
r_int, g_int, b_int = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
target_h, target_s, _ = colorsys.rgb_to_hsv(r_int/255, g_int/255, b_int/255)

# ── Lecture PNG brute (8-bit RGB ou RGBA uniquement) ────────────────────────
def png_read(path):
    with open(path, "rb") as f:
        raw = f.read()
    pos = 8
    width = height = color_type = 0
    idats = []
    while pos < len(raw):
        n = struct.unpack(">I", raw[pos:pos+4])[0]
        t = raw[pos+4:pos+8]
        d = raw[pos+8:pos+8+n]
        if t == b"IHDR":
            width, height = struct.unpack(">II", d[:8])
            color_type = d[9]
        elif t == b"IDAT":
            idats.append(d)
        elif t == b"IEND":
            break
        pos += 12 + n
    channels = 4 if color_type == 6 else 3
    unfiltered = zlib.decompress(b"".join(idats))
    stride = 1 + width * channels
    rows = []
    for y in range(height):
        base = y * stride
        filt = unfiltered[base]
        row = bytearray(unfiltered[base+1 : base+1+width*channels])
        # Appliquer le filtre PNG de la ligne
        if filt == 1:   # Sub
            for i in range(channels, len(row)):
                row[i] = (row[i] + row[i-channels]) & 0xFF
        elif filt == 2: # Up
            if y > 0:
                prev = rows[y-1]
                for i in range(len(row)):
                    row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3: # Average
            prev = rows[y-1] if y > 0 else bytearray(len(row))
            for i in range(len(row)):
                a = row[i-channels] if i >= channels else 0
                row[i] = (row[i] + (a + prev[i]) // 2) & 0xFF
        elif filt == 4: # Paeth
            prev = rows[y-1] if y > 0 else bytearray(len(row))
            for i in range(len(row)):
                a = row[i-channels] if i >= channels else 0
                b2 = prev[i]
                c = prev[i-channels] if i >= channels else 0
                p = a + b2 - c
                pa, pb, pc = abs(p-a), abs(p-b2), abs(p-c)
                pr2 = a if pa <= pb and pa <= pc else (b2 if pb <= pc else c)
                row[i] = (row[i] + pr2) & 0xFF
        rows.append(row)
    return rows, width, height, channels

rows, width, height, channels = png_read(src)

# ── Rotation de teinte ───────────────────────────────────────────────────────
out_rows = []
for row in rows:
    out_row = bytearray(len(row))
    for x in range(width):
        i = x * channels
        pr, pg, pb = row[i], row[i+1], row[i+2]
        pa = row[i+3] if channels == 4 else 255
        h, s, v = colorsys.rgb_to_hsv(pr/255, pg/255, pb/255)
        # Préserver les zones neutres (faible saturation)
        if s > 0.12 and v > 0.05:
            h = target_h
            # Mixer la saturation vers la cible selon la saturation originale
            s = s * 0.3 + target_s * 0.7
        nr, ng, nb = colorsys.hsv_to_rgb(h, s, v)
        out_row[i]   = round(nr * 255)
        out_row[i+1] = round(ng * 255)
        out_row[i+2] = round(nb * 255)
        if channels == 4:
            out_row[i+3] = pa
    out_rows.append(out_row)

# ── Écriture PNG ─────────────────────────────────────────────────────────────
def png_write(path, rows, width, height, channels):
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    ct = 6 if channels == 4 else 2
    ihdr = struct.pack(">IIBBBBB", width, height, 8, ct, 0, 0, 0)
    raw = b""
    for row in rows:
        raw += b"\x00" + bytes(row)
    idat = zlib.compress(raw, 9)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))

png_write(dst, out_rows, width, height, channels)
print(f"tint OK target_h={target_h:.3f}", flush=True)
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


# ── 6) Exécutable : symlink vers le binaire source + wrapper open_arg ────────
# Symlinker le vrai binaire source dans MacOS/ du clone avec le nom "launcher".
# macOS identifie les apps par (binaire + bundle) — le même binaire dans un
# bundle différent (CFBundleIdentifier unique) = app distincte dans le Dock.
SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_EXE_NAME="$(defaults read "$SRC_PLIST" CFBundleExecutable 2>/dev/null || true)"
SRC_EXE="$SOURCE_APP/Contents/MacOS/$SRC_EXE_NAME"

if [[ -z "$SRC_EXE_NAME" || ! -f "$SRC_EXE" ]]; then
  echo "Exécutable source introuvable : $SRC_EXE"
  exit 1
fi

# Symlink du vrai binaire sous le nom attendu par Info.plist (launcher)
ln -sf "$SRC_EXE" "$MACOS/launcher"
echo "EXE_SYMLINK=$SRC_EXE -> $MACOS/launcher"

# Script wrapper pour passer open_arg au démarrage si défini
if [[ -n "$OPEN_ARG" ]]; then
  # Remplacer le symlink par un wrapper shell qui relance le binaire avec l'arg
  rm "$MACOS/launcher"
  cat > "$MACOS/launcher" <<WRAPEOF
#!/bin/zsh
exec "$SRC_EXE" "$OPEN_ARG" "\$@"
WRAPEOF
  chmod +x "$MACOS/launcher"
  echo "WRAPPER with OPEN_ARG=$OPEN_ARG"
fi

cat > "$RES/config.sh" <<CONF
SOURCE_APP="$SOURCE_APP"
OPEN_ARG="$OPEN_ARG"
CONF


# ── 7) Dock ──────────────────────────────────────────────────────────────────
touch "$DEST"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DEST" >/dev/null 2>&1 || true

# Édition directe du plist Dock puis killall Dock + re-register pour icône correcte
python3 - "$DEST" <<'DOCKEOF'
import sys, plistlib, os, subprocess, time

app_path   = sys.argv[1]
plist_path = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")
lsr        = ("/System/Library/Frameworks/CoreServices.framework"
              "/Frameworks/LaunchServices.framework/Support/lsregister")

with open(plist_path, 'rb') as f:
    dock = plistlib.load(f)

apps = dock.get('persistent-apps', [])
url  = app_path.rstrip('/') + '/'

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

# Enregistrer le bundle AVANT de redémarrer le Dock pour qu'il lise la bonne icône
subprocess.run([lsr, '-f', app_path], capture_output=True)
time.sleep(1)
subprocess.run(['killall', 'Dock'], check=False)
print(f"Ajouté au Dock : {app_path}")
DOCKEOF

echo "$DEST"
