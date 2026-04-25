#!/bin/zsh
# apps/AppCloner.app/Contents/Resources/clone_app.sh
# Usage: clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>
#
# Stub-bundle approach (NOT full clone): we create a tiny ~50 KB bundle that
# acts purely as a Dock identity card + launcher. The real source app (VSCode,
# Slack, etc.) is launched untouched via `open -n` with the env var
# `__CFBundleIdentifier` overriding the NSApp bundle identifier. LaunchServices
# then tracks the new VSCode instance under OUR bundle id → Dock shows our
# tinted icon on that instance's window, and `--user-data-dir` gives it a
# fully isolated profile (distinct settings/extensions/state).
#
# Why this works where full-clone fails on macOS Tahoe 26:
#   * no re-signing of 6500 files in the source bundle
#   * no tampering of Apple-notarized Mach-O → no CodeSigningMonitor
#   * no Electron ASAR integrity checks triggered
#   * stub is plain ad-hoc signed, no hardened runtime, no entitlements

DIAG=/tmp/clone_diag.log
: > "$DIAG"

log() {
	# Everything goes into one unified diag file so the user only cats one thing
	echo "$@" >> "$DIAG"
}

# Also echo clone_app.sh's own stdout/stderr into the diag for completeness
exec > >(tee -a "$DIAG") 2>&1

set -euo pipefail

SOURCE_APP="${1:-}"
CLONE_NAME="${2:-}"
COLOR_HEX="${3:-}"
OPEN_ARG="${4:-}"

log "============================================================"
log "=== AppCloner (stub mode) — $(date)"
log "=== SOURCE=$SOURCE_APP"
log "=== NAME=$CLONE_NAME  COLOR=$COLOR_HEX  ARG=$OPEN_ARG"
log "============================================================"

[[ -z "$SOURCE_APP" ]] && { echo "Error: SOURCE_APP missing"; exit 1; }
[[ ! -d "$SOURCE_APP" ]] && { echo "Error: source not found: $SOURCE_APP"; exit 1; }




# ===============================
# ===============================
# ======= 1/ Paths & setup ======
# ===============================
# ===============================

safe_name="$(printf '%s' "$CLONE_NAME" | tr ':/' '-' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ -z "$safe_name" ]] && safe_name="Clone"

APPS_DIR="$HOME/Applications"
mkdir -p "$APPS_DIR"
DEST="$APPS_DIR/${safe_name}.app"
[[ -e "$DEST" ]] && DEST="$APPS_DIR/${safe_name}_$(date +%s).app"

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT

UNIQUE_ID="fr.b519hs.clone.$(date +%s)"

# Per-clone isolated user-data-dir. Each clone gets its own VSCode profile —
# separate settings, extensions, window state, recent folders, etc. Stored
# under Application Support so it survives across reboots and shows up in
# macOS' standard per-app data conventions.
USER_DATA_DIR="$HOME/Library/Application Support/AppCloner/$(echo "$UNIQUE_ID" | tr '.' '_')"
mkdir -p "$USER_DATA_DIR"

log "DEST=$DEST"
log "UNIQUE_ID=$UNIQUE_ID"
log "USER_DATA_DIR=$USER_DATA_DIR"




# =========================================
# =========================================
# ======= 2/ Extract source icon PNG ======
# =========================================
# =========================================

SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_ICON_FILE="$(defaults read "$SRC_PLIST" CFBundleIconFile 2>/dev/null || true)"
[[ -n "$SRC_ICON_FILE" && "${SRC_ICON_FILE##*.}" != "icns" ]] && SRC_ICON_FILE="${SRC_ICON_FILE}.icns"

SRC_ICNS=""
[[ -n "$SRC_ICON_FILE" && -f "$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE" ]] \
	&& SRC_ICNS="$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE"
[[ -z "$SRC_ICNS" ]] \
	&& SRC_ICNS="$(find "$SOURCE_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -n1 || true)"
log "SRC_ICNS=$SRC_ICNS"

BASE_PNG="$TMPDIR_WORK/base.png"
if [[ -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
	ICONSET_TMP="$TMPDIR_WORK/src.iconset"
	iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" 2>/dev/null || true
	for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256"; do
		[[ -f "$ICONSET_TMP/${sz}.png" ]] && cp "$ICONSET_TMP/${sz}.png" "$BASE_PNG" && log "PNG: $sz" && break
	done
fi
if [[ ! -f "$BASE_PNG" ]]; then
	# Fallback: synthesize a generic placeholder icon from the app's first two letters
	log "Fallback generic icon"
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




# ==========================================================
# ==========================================================
# ======= 3/ Tint — pure Python HSV hue rotation ==========
# ==========================================================
# ==========================================================

# No AppleScript, no external dependency. Read/write PNG via struct+zlib,
# rotate hue of every saturated pixel toward the target, preserve B/W regions.
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'TINTEOF'
import sys, colorsys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
r_int, g_int, b_int = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
target_h, target_s, _ = colorsys.rgb_to_hsv(r_int/255, g_int/255, b_int/255)

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
		if filt == 1:
			for i in range(channels, len(row)):
				row[i] = (row[i] + row[i-channels]) & 0xFF
		elif filt == 2:
			if y > 0:
				prev = rows[y-1]
				for i in range(len(row)):
					row[i] = (row[i] + prev[i]) & 0xFF
		elif filt == 3:
			prev = rows[y-1] if y > 0 else bytearray(len(row))
			for i in range(len(row)):
				a = row[i-channels] if i >= channels else 0
				row[i] = (row[i] + (a + prev[i]) // 2) & 0xFF
		elif filt == 4:
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

out_rows = []
for row in rows:
	out_row = bytearray(len(row))
	for x in range(width):
		i = x * channels
		pr, pg, pb = row[i], row[i+1], row[i+2]
		pa = row[i+3] if channels == 4 else 255
		h, s, v = colorsys.rgb_to_hsv(pr/255, pg/255, pb/255)
		if s > 0.12 and v > 0.05:
			h = target_h
			s = s * 0.3 + target_s * 0.7
		nr, ng, nb = colorsys.hsv_to_rgb(h, s, v)
		out_row[i]   = round(nr * 255)
		out_row[i+1] = round(ng * 255)
		out_row[i+2] = round(nb * 255)
		if channels == 4:
			out_row[i+3] = pa
	out_rows.append(out_row)

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

[[ ! -f "$TINTED_PNG" ]] && { log "Tint failed — using base PNG"; cp "$BASE_PNG" "$TINTED_PNG"; }




# =====================================
# =====================================
# ======= 4/ Build tinted .icns ======
# =====================================
# =====================================

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
log "icns built"




# ===========================================
# ===========================================
# ======= 5/ Write stub Info.plist =========
# ===========================================
# ===========================================

# The stub's Info.plist declares a fresh CFBundleIdentifier. LaunchServices
# registers this identifier and, when VSCode is spawned with the env var
# __CFBundleIdentifier pointing here, the Dock looks up the icon via this
# identifier → finds our bundle → shows the tinted icon on the running
# VSCode window.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>launcher</string>
	<key>CFBundleIdentifier</key><string>${UNIQUE_ID}</string>
	<key>CFBundleName</key><string>${safe_name}</string>
	<key>CFBundleDisplayName</key><string>${safe_name}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST




# ==============================================
# ==============================================
# ======= 6/ Write launcher shell script ======
# ==============================================
# ==============================================

# The launcher does exactly three things:
#   1. Export __CFBundleIdentifier with our unique id. Chromium/Electron
#      (and CoreFoundation in general) honor this env var to override the
#      NSApp bundle identifier at startup — Dock then groups VSCode under
#      our id instead of com.microsoft.VSCode.
#   2. `exec` into the source app via `open -n -a`. `open` is LaunchServices-
#      aware so the env var propagates into the spawned VSCode process.
#      `-n` forces a new instance so each clone gets its own process tree.
#   3. Pass `--user-data-dir=…` to VSCode so the instance has a dedicated
#      settings/extensions profile, and forward the user's OPEN_ARG folder.
#
# Single-quote the heredoc so zsh doesn't expand $CFBundleIdentifier / $HOME
# / $@ at script-write time — we want those expanded at launch time inside
# the stub.
LAUNCHER="$MACOS/launcher"
cat > "$LAUNCHER" <<LAUNCHEREOF
#!/bin/zsh
# Generated by AppCloner. Do not edit — regenerated on each clone.
set -e

SOURCE_APP="${SOURCE_APP}"
OPEN_ARG="${OPEN_ARG}"
UNIQUE_ID="${UNIQUE_ID}"
USER_DATA_DIR="${USER_DATA_DIR}"

# Override the bundle identifier seen by the spawned process → Dock tracks
# this VSCode instance under our stub identity, displaying the tinted icon
export __CFBundleIdentifier="\$UNIQUE_ID"

# Build the argument list for VSCode. VSCode's main binary is picky about
# spacing; quote every path.
ARGS=(--user-data-dir "\$USER_DATA_DIR" --new-window)
if [[ -n "\$OPEN_ARG" ]]; then
	ARGS+=("\$OPEN_ARG")
fi

# Launch via \`open -n\` so LaunchServices registers the instance under
# our env-overridden bundle id. -n = new instance even if one is running.
exec /usr/bin/open -n -a "\$SOURCE_APP" --args "\${ARGS[@]}"
LAUNCHEREOF
chmod +x "$LAUNCHER"
log "launcher written"




# ===========================================
# ===========================================
# ======= 7/ Ad-hoc sign the tiny stub =====
# ===========================================
# ===========================================

# Tiny bundle, shell-script executable, no hardened runtime, no entitlements.
# codesign handles it in < 1 s and macOS Tahoe's CodeSigningMonitor has no
# notarized baseline to compare against — nothing for it to flag.
codesign --force --sign - "$DEST" >> "$DIAG" 2>&1 || true
log "stub signed"




# ========================================
# ========================================
# ======= 8/ Register + add to Dock =====
# ========================================
# ========================================

touch "$DEST"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DEST" >/dev/null 2>&1 || true

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
		print("Already in Dock")
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

# Unregister + force-register (recursive) before killing Dock so it reads
# the right metadata on restart — without this, single-kill races produce
# the dreaded "?" placeholder
subprocess.run([lsr, '-u', app_path], capture_output=True)
subprocess.run([lsr, '-f', '-r', app_path], capture_output=True)
time.sleep(2)
subprocess.run(['killall', 'Dock'], check=False)
print(f"Added to Dock: {app_path}")
DOCKEOF




# ========================================
# ========================================
# ======= 9/ Post-create diagnostic =====
# ========================================
# ========================================

# No test launch here — on success the clone will actually open VSCode with
# its own user-data-dir, which would be intrusive to do inside a short-lived
# shell script. Instead dump the static state so the user can verify the
# stub is well-formed.
{
	echo ""
	echo "============================================================"
	echo "=== Post-create diagnostic — $(date)"
	echo "============================================================"
	echo ""
	echo "── Stub bundle ─────────────────────────────────────────────"
	echo "DEST=$DEST"
	du -sh "$DEST"
	echo ""
	echo "── Info.plist ──────────────────────────────────────────────"
	cat "$CONTENTS/Info.plist"
	echo ""
	echo "── launcher ────────────────────────────────────────────────"
	cat "$LAUNCHER"
	echo ""
	echo "── codesign -dv ────────────────────────────────────────────"
	codesign -dv --verbose=2 "$DEST" 2>&1 || true
	echo ""
	echo "── LaunchServices registration ─────────────────────────────"
	"$LSR" -dump 2>/dev/null | grep -A 3 "$UNIQUE_ID" | head -20 || true
	echo ""
	echo "=== End of diagnostic ==="
} >> "$DIAG" 2>&1

echo ""
echo "Diagnostic written to $DIAG"
echo "$DEST"
