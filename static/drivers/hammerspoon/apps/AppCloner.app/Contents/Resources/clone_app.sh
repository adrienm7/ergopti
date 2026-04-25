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

# Resolve source app's main executable name once, up front — needed by both
# the family-detection and the launcher generation.
SRC_EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "")"
SRC_EXE="$SOURCE_APP/Contents/MacOS/$SRC_EXE_NAME"
if [[ -z "$SRC_EXE_NAME" || ! -f "$SRC_EXE" ]]; then
	echo "Error: cannot resolve source executable ($SRC_EXE)"; exit 1
fi
log "SRC_EXE=$SRC_EXE"

log "DEST=$DEST"
log "UNIQUE_ID=$UNIQUE_ID"

# Detect the source app's flavor so the launcher script can pass the right
# args. We support three families:
#   * VSCode-like      (Electron + supports --user-data-dir + --extensions-dir
#                       + --new-window). Detected by Frameworks/Electron + a
#                       Code-like CLI bin.
#   * Generic Electron (Slack, Discord, Notion, ...). Supports --user-data-dir
#                       but not the VSCode-specific flags.
#   * Native           (Calculator, Mail, Safari, ...). No user-data-dir
#                       concept — only the __CFBundleIdentifier override
#                       gives them a distinct Dock identity.
APP_FAMILY=native
if [[ -d "$SOURCE_APP/Contents/Frameworks/Electron Framework.framework" ]]; then
	APP_FAMILY=electron
	if [[ -f "$SOURCE_APP/Contents/Resources/app/bin/code" ]] \
	   || [[ "$SRC_EXE_NAME" == "Code" ]] \
	   || [[ "$SRC_EXE_NAME" == "Code - Insiders" ]]; then
		APP_FAMILY=vscode
	fi
fi
log "APP_FAMILY=$APP_FAMILY"

# Per-clone user-data-dir under Application Support — only meaningful for
# Electron-based apps. We still create the directory unconditionally so
# downstream code doesn't have to special-case empty paths.
USER_DATA_DIR="$HOME/Library/Application Support/AppCloner/${safe_name}"
mkdir -p "$USER_DATA_DIR"

# VSCode-specific extras: shared extensions dir + symlinked User/ subdir,
# so the clone inherits settings/keybindings/snippets/themes/globalStorage
# from the main VSCode instance and doesn't re-install extensions.
SHARED_EXT_DIR="$HOME/.vscode/extensions"
if [[ "$APP_FAMILY" == "vscode" ]]; then
	MAIN_VSCODE_DATA="$HOME/Library/Application Support/Code"
	if [[ -d "$MAIN_VSCODE_DATA/User" && ! -e "$USER_DATA_DIR/User" ]]; then
		ln -s "$MAIN_VSCODE_DATA/User" "$USER_DATA_DIR/User"
		log "Symlinked User/ → main VSCode user data"
	fi
fi
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

# We directly `exec` the source app's main binary instead of going through
# `open`. Reason: the `open` CLI on macOS re-launches the target via
# LaunchServices and, in the process, sanitizes environment variables
# including `__CFBundleIdentifier`. A direct `exec` from our shell keeps
# the env var intact across the exec boundary so CoreFoundation inside
# VSCode reads it at NSBundle.mainBundle initialization, registering the
# new process under OUR bundle id with the Dock — a single tinted tile
# instead of ours+VSCode's side by side.
#
# The exec'd process's mapped executable path is VSCode's binary, but
# CoreFoundation's identifier resolution honors __CFBundleIdentifier
# when present. This is the same technique Chromium itself uses to give
# its helper processes distinct identities.

# Build the per-family argument array. VSCode-only flags are skipped for
# generic Electron apps and natives.
case "$APP_FAMILY" in
	vscode)
		LAUNCHER_ARGS_LITERAL='ARGS=(
	--user-data-dir "'"$USER_DATA_DIR"'"
	--extensions-dir "'"$SHARED_EXT_DIR"'"
	--new-window
)' ;;
	electron)
		LAUNCHER_ARGS_LITERAL='ARGS=(--user-data-dir "'"$USER_DATA_DIR"'")' ;;
	native|*)
		LAUNCHER_ARGS_LITERAL='ARGS=()' ;;
esac

cat > "$LAUNCHER" <<LAUNCHEREOF
#!/bin/zsh
# Generated by AppCloner. Do not edit — regenerated on each clone.
set -e

# Override the NSApp bundle identifier seen by the spawned process → Dock
# associates the running VSCode window with our stub tile, displaying the
# tinted icon instead of VSCode's default blue one beside ours.
export __CFBundleIdentifier="${UNIQUE_ID}"

# Family-specific launch args. VSCode gets the full triplet so it shares
# extensions and settings with the user's main install. Generic Electron
# apps just get an isolated user-data-dir. Native apps run with no flags.
${LAUNCHER_ARGS_LITERAL}
OPEN_ARG="${OPEN_ARG}"
if [[ -n "\$OPEN_ARG" ]]; then
	ARGS+=("\$OPEN_ARG")
fi

# Force the native architecture. VSCode ships a universal Mach-O (x86_64 +
# arm64) and the kernel picks an arch by inheritance from the parent
# process. If anything in the launch chain (Dock, launchd, parent shell)
# was running under Rosetta, the inheritance silently sticks us at x86_64
# and VSCode complains "you're running emulated, install native arm".
#
# \`uname -m\` is unreliable here because it returns the *current process*
# arch, which inherits the same Rosetta stickiness. \`sysctl hw.optional.arm64\`
# queries the kernel directly and returns "1" on every Apple Silicon Mac
# regardless of the asking process's arch — that's what we need.
if [[ "\$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then
	NATIVE_ARCH=arm64
else
	NATIVE_ARCH=x86_64
fi

# Direct exec — no \`open\`, no LaunchServices scrubbing of our env
exec /usr/bin/arch -"\$NATIVE_ARCH" "${SRC_EXE}" "\${ARGS[@]}"
LAUNCHEREOF
chmod +x "$LAUNCHER"
log "launcher written (direct exec of $SRC_EXE)"




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

# Bundle id is needed inside the Dock plist entry so Dock resolves the
# icon via LaunchServices (= reads our Info.plist) instead of falling back
# to the Finder's path-based lookup which tends to find a stale system
# icon. The `book` field — an NSURL bookmark blob — is what manual
# drag-to-Dock generates and what makes the entry survive moves.
python3 - "$DEST" "$UNIQUE_ID" <<'DOCKEOF'
import sys, plistlib, os, subprocess, time

app_path     = sys.argv[1]
bundle_id    = sys.argv[2]
plist_path   = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")
lsr          = ("/System/Library/Frameworks/CoreServices.framework"
                "/Frameworks/LaunchServices.framework/Support/lsregister")

# Generate a real NSURL bookmark blob via PyObjC. This is the same data
# Finder writes when you drag an .app onto the Dock — it lets the Dock
# track the bundle by inode rather than by path, so renames/moves don't
# break the tile, and the tile resolves the correct icon via LS.
def make_bookmark(path):
	try:
		from Foundation import NSURL
		url = NSURL.fileURLWithPath_(path)
		bookmark, err = url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error_(
			0, None, None, None
		)
		if bookmark is None:
			return None
		return bytes(bookmark)
	except Exception as e:
		print(f"Bookmark generation failed ({e}); Dock will fall back to path-only entry")
		return None

with open(plist_path, 'rb') as f:
	dock = plistlib.load(f)

apps = dock.get('persistent-apps', [])
url  = app_path.rstrip('/') + '/'

# If the same app is already pinned, remove it so we always end up with a
# fresh, correct entry (manual re-drag behavior). Avoids stale entries
# pointing at obsolete clone paths after re-clones with the same name.
apps = [
	e for e in apps
	if e.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '') != url
]

label = os.path.basename(app_path).removesuffix('.app')
tile_data = {
	'bundle-identifier': bundle_id,
	'dock-extra': False,
	'file-data': {
		'_CFURLString': 'file://' + app_path.replace(' ', '%20').rstrip('/') + '/',
		'_CFURLStringType': 15,
	},
	'file-label': label,
	'file-mod-date': 0,
	'file-type': 41,
	'parent-mod-date': 0,
}
book = make_bookmark(app_path)
if book is not None:
	tile_data['book'] = book

apps.append({
	'GUID': int.from_bytes(os.urandom(4), 'big'),
	'tile-data': tile_data,
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
