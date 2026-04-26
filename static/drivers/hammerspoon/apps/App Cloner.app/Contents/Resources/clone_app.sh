#!/bin/zsh
# apps/App Cloner.app/Contents/Resources/clone_app.sh
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
ICON_MODE="${5:-tint}"   # tint | bw | custom
ICON_PATH="${6:-}"        # only used when ICON_MODE=custom
PWA_MODE="${7:-0}"        # 1 = clone is an Edge PWA pointing at OPEN_ARG (URL)
URL_LOCK="${8:-0}"        # 1 = PWA refuses to navigate away from OPEN_ARG (out-of-scope URLs are dispatched to SOURCE_APP)

log "============================================================"
log "=== AppCloner (stub mode) — $(date)"
log "=== SOURCE=$SOURCE_APP"
log "=== NAME=$CLONE_NAME  COLOR=$COLOR_HEX  ARG=$OPEN_ARG"
log "=== ICON_MODE=$ICON_MODE  ICON_PATH=$ICON_PATH  PWA=$PWA_MODE  URL_LOCK=$URL_LOCK"
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
# Sandboxed apps such as the new Microsoft Teams or Outlook cannot be cloned
# this way (signature/entitlement checks defeat any binary-level patching);
# the menu offers a separate «PWA mode» for those — see Section 6.b.
APP_FAMILY=native
# Standard Electron detection: vendored Electron Framework
if [[ -d "$SOURCE_APP/Contents/Frameworks/Electron Framework.framework" ]]; then
	APP_FAMILY=electron
fi
# Chromium Embedded Framework wrappers also accept --user-data-dir
for fw in "$SOURCE_APP/Contents/Frameworks"/*.framework(N); do
	case "${fw:t}" in
		"Chromium Embedded Framework.framework"|"Chromium Framework.framework")
			APP_FAMILY=electron ;;
	esac
done
# Catch by executable name when frameworks are renamed/hidden
case "$SRC_EXE_NAME" in
	"Slack"|"Discord"|"Notion"|"Spotify"|"Figma"|"Postman")
		APP_FAMILY=electron ;;
esac
# VSCode is Electron too but with extra CLI flags worth passing
if [[ -f "$SOURCE_APP/Contents/Resources/app/bin/code" ]] \
   || [[ "$SRC_EXE_NAME" == "Code" ]] \
   || [[ "$SRC_EXE_NAME" == "Code - Insiders" ]]; then
	APP_FAMILY=vscode
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

# Custom icon path: skip the source-app extraction entirely and convert the
# user-provided image (PNG/JPG/HEIC/SVG/ICNS) into our working PNG. sips
# handles every macOS image format; for icns we extract the largest slice.
if [[ "$ICON_MODE" == "custom" && -n "$ICON_PATH" && -f "$ICON_PATH" ]]; then
	if [[ "${ICON_PATH:l}" == *.icns ]]; then
		ICONSET_TMP="$TMPDIR_WORK/custom.iconset"
		iconutil -c iconset "$ICON_PATH" -o "$ICONSET_TMP" 2>/dev/null || true
		for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256"; do
			[[ -f "$ICONSET_TMP/${sz}.png" ]] && cp "$ICONSET_TMP/${sz}.png" "$BASE_PNG" && break
		done
	else
		# Convert anything else to a 1024-square PNG with a pure-white background.
		# sips -z pads transparent areas with a grayish tint; Python + AppKit lets us
		# fill the canvas with #FFFFFF before compositing the image on top.
		python3 - "$ICON_PATH" "$BASE_PNG" <<'CUSTOMICONEOF' 2>/dev/null || true
import sys
from AppKit import (
	NSImage, NSBitmapImageRep, NSPNGFileType,
	NSGraphicsContext, NSColor, NSCompositingOperationSourceOver, NSBezierPath
)
from Foundation import NSMakeRect

src, dst = sys.argv[1], sys.argv[2]
img = NSImage.alloc().initWithContentsOfFile_(src)
if img is None:
	sys.exit(1)

target = 1024
w = img.size().width
h = img.size().height
scale = target / max(w, h, 1)
nw, nh = int(w * scale), int(h * scale)
x, y = (target - nw) // 2, (target - nh) // 2

bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
	None, target, target, 8, 4, True, False, "NSDeviceRGBColorSpace", 0, 32
)
ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.setCurrentContext_(ctx)
# Pure white canvas — avoids the grayish tint sips leaves on transparent areas
NSColor.whiteColor().setFill()
NSBezierPath.fillRect_(NSMakeRect(0, 0, target, target))
img.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
	NSMakeRect(x, y, nw, nh),
	NSMakeRect(0, 0, 0, 0),
	NSCompositingOperationSourceOver,
	1.0, True, None
)
NSGraphicsContext.restoreGraphicsState()
png = bitmap.representationUsingType_properties_(NSPNGFileType, None)
png.writeToFile_atomically_(dst, True)
CUSTOMICONEOF
	fi
	if [[ -f "$BASE_PNG" ]]; then
		log "Custom icon source: $ICON_PATH"
	else
		log "Custom icon conversion failed — falling back to source app icon"
	fi
fi

if [[ ! -f "$BASE_PNG" && -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
	ICONSET_TMP="$TMPDIR_WORK/src.iconset"
	iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" 2>/dev/null || true
	for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256"; do
		[[ -f "$ICONSET_TMP/${sz}.png" ]] && cp "$ICONSET_TMP/${sz}.png" "$BASE_PNG" && log "PNG: $sz" && break
	done
fi

# Fallback for apps that don't ship a plain .icns (notably the new Microsoft
# Teams + most Mac App Store apps that pack icons into Assets.car). Ask
# NSWorkspace for the icon as Finder displays it — this works regardless of
# how the icon is stored (icns, asset catalog, doc-icon plugin…).
if [[ ! -f "$BASE_PNG" ]]; then
	log "No .icns found — falling back to NSWorkspace.iconForFile"
	python3 - "$SOURCE_APP" "$BASE_PNG" <<'NSWSEOF' || true
import sys
from AppKit import (
	NSWorkspace, NSBitmapImageRep, NSPNGFileType, NSGraphicsContext,
	NSDeviceRGBColorSpace, NSCompositingOperationCopy
)
from Foundation import NSMakeSize, NSMakeRect

src, dst = sys.argv[1], sys.argv[2]
img = NSWorkspace.sharedWorkspace().iconForFile_(src)
if img is None:
	sys.exit(1)

# Pick the largest representation NSImage holds. Apps with asset catalogs
# (Teams, Slack…) typically include 1024×1024; older apps top out at 512.
# Without picking explicitly, TIFFRepresentation can return a tiny rep that
# scales up garbage-looking when we later push it through sips/iconutil.
reps = img.representations()
best_rep = None
for r in reps:
	if best_rep is None or r.pixelsWide() > best_rep.pixelsWide():
		best_rep = r
target_w = max(best_rep.pixelsWide() if best_rep else 1024, 1024)
target_h = max(best_rep.pixelsHigh() if best_rep else 1024, 1024)

# Draw the NSImage into a fresh RGBA bitmap at the target resolution. This
# forces Cocoa to use its best rep + proper scaling, instead of returning
# whatever happens to be cached.
bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
	None, target_w, target_h, 8, 4, True, False,
	NSDeviceRGBColorSpace, 0, 32
)
ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.setCurrentContext_(ctx)
img.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
	NSMakeRect(0, 0, target_w, target_h),
	NSMakeRect(0, 0, 0, 0),  # zero-size source = use full image
	NSCompositingOperationCopy,
	1.0,
	True,
	None
)
NSGraphicsContext.restoreGraphicsState()
png = bitmap.representationUsingType_properties_(NSPNGFileType, None)
png.writeToFile_atomically_(dst, True)
print(f"NSWorkspace icon extracted at {target_w}×{target_h} → {dst}", flush=True)
NSWSEOF
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

# Three icon modes:
#   * tint:   pixel-by-pixel hue rotation toward COLOR_HEX (existing behavior)
#   * bw:     drop saturation to 0 → true grayscale, keeping luminance
#   * custom: user provided a finished image — pass through, no processing
TINTED_PNG="$TMPDIR_WORK/tinted.png"

if [[ "$ICON_MODE" == "custom" ]]; then
	# Already correct in BASE_PNG, just hand off
	cp "$BASE_PNG" "$TINTED_PNG"
	log "Icon mode: custom (no processing)"
	# Skip the Python tint block by short-circuiting via parsed args that
	# the script itself reads as harmless. Easier: gate the python call
	# with an outer if/else.
fi

if [[ "$ICON_MODE" != "custom" ]]; then

R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" "$ICON_MODE" <<'TINTEOF'
import sys, colorsys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
r_int, g_int, b_int = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
mode = sys.argv[6] if len(sys.argv) > 6 else "tint"
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
		if mode == "bw":
			# Use perceptual luminance (Rec. 709) — NOT HSV "Value", which
			# is just max(R,G,B) and would map saturated colors (Teams's
			# purple, Slack's red) to near-white instead of mid-gray.
			y = 0.2126 * (pr/255) + 0.7152 * (pg/255) + 0.0722 * (pb/255)
			nr = ng = nb = y
		else:
			if s > 0.12 and v > 0.05:
				# Hue-rotate toward target color, blend saturation to feel natural
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
print(f"icon OK mode={mode} target_h={target_h:.3f}", flush=True)
TINTEOF

fi  # end of "ICON_MODE != custom" block

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
if [[ "${APPCLONER_SKIP_STUB:-0}" != "1" ]]; then
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




# ====================================================================
# ====================================================================
# ======= 6.b/ PWA mode — clone is an Edge web app ===================
# ====================================================================
# ====================================================================

# When the user ticks «mode PWA» the clone is no longer a stub that re-
# launches the source desktop app. Instead it spawns Microsoft Edge (or
# Chrome / Brave as fallback) in --app=URL mode with an isolated user-data
# dir. The result is a chromeless, single-window web app — fully isolated
# from the user's main browser session, and from any other clone — that
# can be logged into independently. This is the only reliable way to get
# multiple sandboxed apps (Teams new, Outlook for Mac) running side by
# side on macOS without Microsoft's signing key.
if [[ "$PWA_MODE" == "1" ]]; then
	# WKWebView mode: the launcher hosts the web app directly via WebKit, no
	# Edge/Chrome dependency at runtime. The clone IS the app — Mission Control
	# shows our name, Space pinning by our bundle-id is honored natively, and
	# the bundle stays small (~tens of KB) so signing is trivial.
	log "PWA mode: WKWebView launcher (no external browser)"

	# Per-clone WKWebView data store — keeps cookies/localStorage of each
	# PWA isolated. With WKWebView, the default data store is per-bundle, so
	# each clone (different bundle-id) is naturally isolated. We still keep
	# this directory for the launcher's hint files (target_space_uuid, etc).
	PWA_PROFILE_DIR="$HOME/Library/Application Support/AppCloner/${safe_name}_pwa"
	mkdir -p "$PWA_PROFILE_DIR"

	# Patch the stub Info.plist with media usage descriptions. The user-facing
	# strings are shown by macOS the first time the WKWebView requests camera
	# or microphone access (e.g. on a Teams call).
	INFO_PLIST="$CONTENTS/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string $CLONE_NAME a besoin de la caméra pour les appels vidéo." "$INFO_PLIST" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :NSCameraUsageDescription $CLONE_NAME a besoin de la caméra pour les appels vidéo." "$INFO_PLIST" 2>>"$DIAG"
	/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string $CLONE_NAME a besoin du micro pour les appels vidéo." "$INFO_PLIST" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription $CLONE_NAME a besoin du micro pour les appels vidéo." "$INFO_PLIST" 2>>"$DIAG"
	# Allow inbound mixed content / WebRTC over local networks (Teams uses LAN
	# negotiation for screen sharing).
	/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$INFO_PLIST" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$INFO_PLIST" 2>/dev/null || true




	# ================================================
	# ===== 6.b.2) Python WKWebView launcher =====
	# ================================================

	# No compilation required — works on any Mac out of the box.
	# The launcher is split into two files:
	#   * Contents/MacOS/launcher  — tiny zsh wrapper that sets CFProcessPath=$0
	#     before exec-ing python3. CoreFoundation reads CFProcessPath to resolve
	#     NSBundle.mainBundle(), giving each clone its unique bundle-id and an
	#     isolated WKWebsiteDataStore (cookies/localStorage per clone, not shared).
	#   * Contents/Resources/pwa_launcher.py — full Cocoa NSApplication via
	#     PyObjC, which ships with macOS's own /usr/bin/python3 (no Xcode, no
	#     Homebrew). WKWebsiteDataStore.defaultDataStore() persists login state
	#     across launches so the user only needs to authenticate once.
	cat > "$LAUNCHER" << 'SHELLEOF'
#!/bin/zsh
# CFProcessPath must point to this bundle's MacOS executable so CoreFoundation
# resolves NSBundle.mainBundle() to THIS clone's bundle (unique bundle-id →
# isolated WKWebsiteDataStore). Without it, python3 would be the main bundle.
export CFProcessPath="$0"
BUNDLE_RES="$(dirname "$(dirname "$0")")/Resources"
exec /usr/bin/python3 "$BUNDLE_RES/pwa_launcher.py" "$@"
SHELLEOF
	chmod +x "$LAUNCHER"

	cat > "$RES/pwa_launcher.py" << PYEOF
#!/usr/bin/env python3
"""PWA WKWebView launcher — generated by App Cloner. Do not edit."""
import sys
import subprocess
import objc
from Foundation import NSObject, NSURL, NSURLRequest, NSMakeRect, NSDistributedNotificationCenter
from AppKit import (
    NSApplication, NSWindow, NSBackingStoreBuffered,
    NSAlert, NSAlertFirstButtonReturn, NSAppearance,
)

# Load WebKit via the framework bundle directly. The system /usr/bin/python3
# ships with a subset of PyObjC that does NOT include the WebKit wrapper
# package, so "from WebKit import ..." raises ImportError at runtime.
try:
    objc.loadBundle(
        "WebKit",
        bundle_path="/System/Library/Frameworks/WebKit.framework",
        module_globals=globals(),
    )
    WKWebView                 = objc.lookUpClass("WKWebView")
    WKWebViewConfiguration    = objc.lookUpClass("WKWebViewConfiguration")
    WKWebsiteDataStore        = objc.lookUpClass("WKWebsiteDataStore")
    WKUserScript              = objc.lookUpClass("WKUserScript")
    WKUserContentController   = objc.lookUpClass("WKUserContentController")
except Exception as _wk_err:
    _tmp_app = NSApplication.sharedApplication()
    _tmp_app.setActivationPolicy_(0)
    _tmp_app.finishLaunching()
    alert = NSAlert.alloc().init()
    alert.setMessageText_("Erreur de démarrage")
    alert.setInformativeText_(
        "Impossible de charger WebKit :\\n" + str(_wk_err) + "\\n\\n"
        "Vérifiez que les Xcode Command Line Tools sont installés."
    )
    alert.addButtonWithTitle_("Fermer")
    alert.runModal()
    sys.exit(1)

OPEN_ARG       = "${OPEN_ARG}"
CLONE_NAME     = "${CLONE_NAME}"
SOURCE_APP     = "${SOURCE_APP}"
URL_LOCK       = "${URL_LOCK}" == "1"

# NSWindowStyleMask: Titled=1 Closable=2 Miniaturizable=4 Resizable=8
# FullSizeContentView (32768) is intentionally omitted: it would extend the
# WKWebView under the titlebar, making dark-mode chrome invisible (white web
# content covers the title area, and DarkAqua text becomes black-on-white).
_WIN_MASK  = 1 | 2 | 4 | 8
# NSViewAutoresizingMask: WidthSizable=2 HeightSizable=16
_VIEW_MASK = 2 | 16

def _is_dark_mode():
    """Return True when macOS is currently in Dark Mode."""
    r = subprocess.run(
        ["defaults", "read", "-g", "AppleInterfaceStyle"],
        capture_output=True, text=True
    )
    return r.returncode == 0 and "Dark" in r.stdout

_DARK_MODE = _is_dark_mode()

# Injected at document start into every frame. Generic fixes that work on
# any PWA — never touches the page's CSS, color-scheme meta, matchMedia,
# or DOM attributes. WKWebView reports prefers-color-scheme correctly
# based on the window's NSAppearance, so the web app picks the right theme
# on its own via its own CSS rules.
#
# Two helpers are injected:
#  1. fetch() credentials helper for graph.microsoft.com, used by web apps
#     that load profile photos via authenticated XHR.
#  2. <img> error recovery: when a cross-origin image fails to load (often
#     because WebKit's ITP stripped cookies on the cross-site request),
#     re-fetch it via fetch(credentials:'include') and swap in a blob URL.
#     This rescues contact avatars in Teams, Outlook, etc. without
#     hard-coding any specific domain.
_INJECT_JS_TPL = r"""
(function() {
    // ===== fetch credentials =====
    const origFetch = window.fetch.bind(window);
    window.fetch = function(input, init) {
        try {
            const url = (typeof input === 'string') ? input
                : (input && input.url) ? input.url : String(input);
            if (url.indexOf('graph.microsoft.com') !== -1) {
                init = Object.assign({}, init || {}, { credentials: 'include' });
            }
        } catch(_) {}
        return origFetch(input, init);
    };

    // ===== <img> cross-origin error recovery =====
    function _attachImgRecovery(img) {
        if (img.__appcloner_hooked) return;
        img.__appcloner_hooked = true;
        img.addEventListener('error', function _onErr() {
            if (img.__appcloner_recovered) return;
            const src = img.getAttribute('src') || '';
            if (!src) return;
            if (src.startsWith('data:') || src.startsWith('blob:') || src.startsWith('file:')) return;
            try {
                const u = new URL(src, location.href);
                if (u.origin === location.origin) return;
            } catch (_) { return; }
            img.__appcloner_recovered = true;
            fetch(src, { credentials: 'include' })
                .then(function(r) { return r.ok ? r.blob() : null; })
                .then(function(blob) { if (blob) img.src = URL.createObjectURL(blob); })
                .catch(function() {});
        });
    }
    function _scanExisting() {
        document.querySelectorAll('img').forEach(_attachImgRecovery);
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', _scanExisting, { once: true });
    } else {
        _scanExisting();
    }
    new MutationObserver(function(records) {
        for (var i = 0; i < records.length; i++) {
            var added = records[i].addedNodes;
            for (var j = 0; j < added.length; j++) {
                var n = added[j];
                if (n.nodeName === 'IMG') _attachImgRecovery(n);
                else if (n.querySelectorAll) {
                    n.querySelectorAll('img').forEach(_attachImgRecovery);
                }
            }
        }
    }).observe(document.documentElement, { childList: true, subtree: true });

    // ===== URL lock (only active when __APPCLONER_LOCK__ is true) =====
    // External dispatch goes through window.open(url, '_blank'), which
    // triggers the UI delegate's createWebViewWithConfiguration:... method.
    // The native side intercepts that call when URL_LOCK is on and dispatches
    // the URL to the source desktop app via `open -a`. This avoids needing a
    // WKNavigationDelegate or a WKScriptMessageHandler — both of which require
    // formal protocol conformance that PyObjC under /usr/bin/python3 does
    // not provide cleanly.
    var _LOCKED = __APPCLONER_LOCK__;
    var _LOCKED_URL = "__APPCLONER_LOCKED_URL__";
    if (_LOCKED && _LOCKED_URL) {
        function _splitFrag(s) {
            var i = (s || '').indexOf('?');
            return i < 0 ? (s || '') : s.substring(0, i);
        }
        function _isLocked(target) {
            try {
                var l = new URL(_LOCKED_URL);
                var t = new URL(target, location.href);
                if (l.protocol !== t.protocol || l.host !== t.host) return false;
                if (l.pathname !== t.pathname) return false;
                return _splitFrag(l.hash) === _splitFrag(t.hash);
            } catch (_) { return false; }
        }
        function _dispatchExternal(url) {
            try { window.open(url, '_blank'); } catch (_) {}
        }
        // Capture-phase click listener: intercept <a> clicks pointing
        // out-of-scope before the SPA framework can route them.
        document.addEventListener('click', function(e) {
            try {
                var a = e.target && e.target.closest && e.target.closest('a[href]');
                if (!a) return;
                var href = a.href || '';
                if (!href || href.indexOf('javascript:') === 0) return;
                if (_isLocked(href)) return;
                e.preventDefault();
                e.stopPropagation();
                _dispatchExternal(href);
            } catch (_) {}
        }, true);
        // SPA navigation hooks: pushState / replaceState / hashchange.
        var origPush = history.pushState.bind(history);
        history.pushState = function(state, title, url) {
            if (url != null && !_isLocked(url)) {
                _dispatchExternal(new URL(url, location.href).href);
                return;
            }
            return origPush(state, title, url);
        };
        var origReplace = history.replaceState.bind(history);
        history.replaceState = function(state, title, url) {
            if (url != null && !_isLocked(url)) {
                _dispatchExternal(new URL(url, location.href).href);
                return;
            }
            return origReplace(state, title, url);
        };
        window.addEventListener('hashchange', function(e) {
            if (!_isLocked(location.href)) {
                _dispatchExternal(location.href);
                try { history.replaceState(null, '', e.oldURL); } catch (_) {}
            }
        });
    }
})();
"""


def _url_in_lock_scope(target):
    """Return True when target URL stays within OPEN_ARG's locked scope.

    Compares scheme, host, path, and the path-portion of the fragment
    (everything before '?'). Query params are ignored on purpose so query
    string changes such as '?ctx=…' or '&var=…' are considered legitimate.
    """
    if not URL_LOCK or not OPEN_ARG or not target:
        return True
    try:
        from urllib.parse import urlparse
        a = urlparse(OPEN_ARG)
        b = urlparse(target)
        if a.scheme != b.scheme or a.netloc != b.netloc:
            return False
        if a.path != b.path:
            return False
        return (a.fragment or "").split("?", 1)[0] == (b.fragment or "").split("?", 1)[0]
    except Exception:
        return False


def _open_in_source_app(url):
    """Dispatch a URL to the source desktop app via `open -a`."""
    if not url:
        return
    try:
        if SOURCE_APP:
            subprocess.run(["open", "-a", SOURCE_APP, url], capture_output=True)
        else:
            subprocess.run(["open", url], capture_output=True)
    except Exception:
        pass


class _WinDelegate(NSObject):
    def windowShouldClose_(self, _win):
        NSApplication.sharedApplication().terminate_(None)
        return True


class _AppDelegate(NSObject):
    _win = None
    _wv  = None
    _wd  = None

    def applicationDidFinishLaunching_(self, _notification):
        self._wd = _WinDelegate.alloc().init()
        # Listen for macOS appearance changes so the window chrome can update
        # live — only the chrome, never the page content.
        NSDistributedNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "systemThemeChanged:", "AppleInterfaceThemeChangedNotification", None
        )
        self._open()
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        url = NSURL.URLWithString_(OPEN_ARG)
        if url:
            self._wv.loadRequest_(NSURLRequest.requestWithURL_(url))

    def systemThemeChanged_(self, _notification):
        """Update window chrome only — never touch the page content."""
        global _DARK_MODE
        _DARK_MODE = _is_dark_mode()
        self._apply_appearance()

    def _apply_appearance(self):
        """Apply appearance for the current _DARK_MODE value.

        Setting appearance to None on the window lets it inherit the system
        appearance — WKWebView then reports prefers-color-scheme: dark correctly.
        Forcing Aqua in light mode prevents the system DarkAqua from leaking in.
        We also sync the app-level appearance so menus and alerts follow.
        """
        app = NSApplication.sharedApplication()
        if _DARK_MODE:
            # None = inherit system (DarkAqua) — window and all subviews including
            # WKWebView report dark to CSS prefers-color-scheme queries.
            if self._win is not None:
                self._win.setAppearance_(None)
            app.setAppearance_(None)
        else:
            if self._win is not None:
                self._win.setAppearance_(NSAppearance.appearanceNamed_("NSAppearanceNameAqua"))
            app.setAppearance_(NSAppearance.appearanceNamed_("NSAppearanceNameAqua"))

    def _open(self):
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 1280, 820), _WIN_MASK, NSBackingStoreBuffered, False
        )
        win.setTitle_(CLONE_NAME)
        win.center()
        win.setDelegate_(self._wd)
        win.setTabbingMode_(2)  # NSWindowTabbingModeDisallowed
        self._win = win
        self._apply_appearance()

        cfg = WKWebViewConfiguration.alloc().init()
        cfg.setWebsiteDataStore_(WKWebsiteDataStore.defaultDataStore())
        cfg.setMediaTypesRequiringUserActionForPlayback_(0)
        # Disable WebKit's Intelligent Tracking Prevention so cross-site auth
        # cookies are not stripped (needed for Microsoft Graph profile photos).
        try:
            cfg.websiteDataStore().setPreventsCrossSiteTracking_(False)
        except Exception:
            pass
        # Allow navigation to any domain — Microsoft auth redirects across many
        # subdomains; app-bound domain restriction would break the flow.
        try:
            cfg.setLimitsNavigationsToAppBoundDomains_(False)
        except Exception:
            pass

        # Inject generic helpers (fetch credentials, <img> error recovery, and
        # — when URL_LOCK is on — click + pushState/hashchange interception).
        # Theme detection is left entirely to WebKit + the page's own CSS.
        # No script-message handler is registered: the JS routes out-of-scope
        # navigation through window.open(_blank), which goes through the
        # already-installed UI delegate. That avoids needing PyObjC to bridge
        # a WKScriptMessageHandler-conforming class.
        ucc = WKUserContentController.alloc().init()
        lock_flag = "true" if URL_LOCK else "false"
        locked_url_js = (OPEN_ARG or "").replace("\\", "\\\\").replace('"', '\\"')
        injected = (_INJECT_JS_TPL
            .replace("__APPCLONER_LOCK__", lock_flag)
            .replace("__APPCLONER_LOCKED_URL__", locked_url_js))
        script = WKUserScript.alloc().initWithSource_injectionTime_forMainFrameOnly_(
            injected, 0, False  # 0 = AtDocumentStart, False = all frames
        )
        ucc.addUserScript_(script)
        cfg.setUserContentController_(ucc)

        wv = WKWebView.alloc().initWithFrame_configuration_(
            win.contentView().bounds(), cfg
        )
        wv.setAutoresizingMask_(_VIEW_MASK)
        wv.setCustomUserAgent_(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
        )
        wv.setUIDelegate_(self)
        win.contentView().addSubview_(wv)
        win.makeKeyAndOrderFront_(None)
        self._wv = wv

    def applicationShouldHandleReopen_hasVisibleWindows_(self, _app, _flag):
        if self._win is None:
            self._open()
            url = NSURL.URLWithString_(OPEN_ARG)
            if url:
                self._wv.loadRequest_(NSURLRequest.requestWithURL_(url))
        else:
            self._win.makeKeyAndOrderFront_(None)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        return True

    def applicationShouldTerminateAfterLastWindowClosed_(self, _app):
        return True

    def webView_createWebViewWithConfiguration_forNavigationAction_windowFeatures_(
            self, wv, _cfg, action, _features):
        # Called when the page calls window.open(url, '_blank') or clicks an
        # <a target="_blank"> link. With targetFrame=None there is no existing
        # frame to receive the request so WKWebView would normally create a
        # second webview — we never want that (the clone is a single-window
        # app). Two cases:
        #   * URL_LOCK on AND target outside lock scope → dispatch to the
        #     source desktop app via `open -a`. Used by the injected JS to
        #     bounce out-of-scope clicks and SPA navigation to the real client.
        #   * Otherwise → load the URL in the existing webview, replacing
        #     whatever is on screen.
        if action.targetFrame() is None:
            req = action.request()
            if req and req.URL():
                target = req.URL().absoluteString()
                if URL_LOCK and not _url_in_lock_scope(target):
                    _open_in_source_app(target)
                else:
                    wv.loadRequest_(req)
        return None


_app = NSApplication.sharedApplication()
_app.setActivationPolicy_(0)  # NSApplicationActivationPolicyRegular
# Initial app-level appearance — _apply_appearance() will refine per-window
# once applicationDidFinishLaunching_ fires, but we set it here early so
# any system dialogs shown before the window is ready already look correct.
if _DARK_MODE:
    _app.setAppearance_(None)
else:
    _app.setAppearance_(NSAppearance.appearanceNamed_("NSAppearanceNameAqua"))
_delegate = _AppDelegate.alloc().init()
_app.setDelegate_(_delegate)
_app.run()
PYEOF
	log "PWA Python launcher written → $LAUNCHER (no compilation needed)"
	log "PWA WKWebView launcher ready — URL=${OPEN_ARG}"
	APPCLONER_PWA_DONE=1
fi

if [[ "${APPCLONER_PWA_DONE:-0}" != "1" ]]; then
cat > "$LAUNCHER" <<LAUNCHEREOF
#!/bin/zsh
# Generated by AppCloner. Do not edit — regenerated on each clone.
set -e

# Override the NSApp bundle identifier seen by the spawned process → Dock
# associates the running window with our stub tile, displaying the
# tinted icon instead of the source app's default one.
export __CFBundleIdentifier="${UNIQUE_ID}"

# Family-specific launch args. VSCode gets the full triplet so it shares
# extensions and settings with the user's main install. Generic Electron
# apps just get an isolated user-data-dir. Native apps run with no flags.
${LAUNCHER_ARGS_LITERAL}
OPEN_ARG="${OPEN_ARG}"

# OPEN_ARG can be:
#   * a folder path        → passed as positional arg (VSCode opens it)
#   * a file path          → same
#   * a URL scheme like
#     msteams:/l/chat/...  → Outlook/Teams handle their own URL handlers,
#     outlook://calendar     so we let macOS dispatch via \`open\` AFTER
#                            the app process is up. Without this, passing
#                            a URL as positional argv to Electron silently
#                            no-ops because the app isn't yet a registered
#                            URL handler in this process tree.
URL_SCHEME_RE='^[a-zA-Z][a-zA-Z0-9+.-]*://'
if [[ -n "\$OPEN_ARG" && ! "\$OPEN_ARG" =~ \$URL_SCHEME_RE ]]; then
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

# Spawn the app in the background so we can dispatch a URL to it after a
# short delay if the user gave us one. If no URL, we still wait on the
# child PID so the launcher's process lifetime tracks the app's — Dock
# tile stays as "running" until the user quits VSCode/Outlook/Teams.
__CFBundleIdentifier="${UNIQUE_ID}" \\
	/usr/bin/arch -"\$NATIVE_ARCH" "${SRC_EXE}" "\${ARGS[@]}" &
APP_PID=\$!

if [[ -n "\$OPEN_ARG" && "\$OPEN_ARG" =~ \$URL_SCHEME_RE ]]; then
	# Give the app ~1 s to register its URL handler with macOS, then
	# dispatch the URL via \`open -a \$SOURCE_APP\` so the URL is opened
	# specifically by the source app, not the system default handler.
	# Without -a, msteams:/ URLs would go to whatever app is registered
	# as URL handler on the user's system (often Edge or web Teams),
	# bypassing the running clone entirely.
	sleep 1
	/usr/bin/open -a "${SOURCE_APP}" "\$OPEN_ARG"
fi

wait "\$APP_PID"
LAUNCHEREOF
chmod +x "$LAUNCHER"
log "launcher written (direct exec of $SRC_EXE)"
fi  # end APPCLONER_PWA_DONE guard




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

fi  # end APPCLONER_SKIP_STUB guard




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
python3 - "$DEST" "$UNIQUE_ID" "$SOURCE_APP" "${PWA_BROWSER:-}" <<'DOCKEOF'
import sys, plistlib, os, subprocess, time

app_path     = sys.argv[1]
bundle_id    = sys.argv[2]
source_app   = sys.argv[3]
pwa_browser  = sys.argv[4] if len(sys.argv) > 4 else ""  # path to Edge/Chrome app, or "" for native mode
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

# Copy the source app's Space assignment to the clone.
#
# macOS stores per-app Space pinning in two places:
#   1. com.apple.dock.plist  →  "workspaces-application-assignments"
#      dict  bundle-id → Space UUID. Only present when the user right-clicked
#      the Dock tile → "Options" → "Assign to this desktop". Mission-Control
#      drag-and-drop does NOT write this key, so the dict is often empty.
#
#   2. com.apple.spaces.plist (binary, read via plutil) → ManagedDisplaySpaces
#      → each Space has a list of app bundle-ids under "apps". This IS written
#      when a window is moved to a Space in Mission Control. We scan it as a
#      fallback to find the Space UUID for the source app.
def _find_space_uuid_in_spaces_plist(src_bundle_id):
    """Scan com.apple.spaces to find which Space UUID hosts src_bundle_id."""
    import json
    spaces_path = os.path.expanduser(
        "~/Library/Preferences/com.apple.spaces.plist"
    )
    try:
        result = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", spaces_path],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
        for display in data.get("ManagedDisplaySpaces", []):
            for space in display.get("Spaces", []):
                uuid = space.get("uuid", "")
                apps = space.get("apps", [])
                if src_bundle_id in apps:
                    return uuid
    except Exception:
        pass
    return None

def _read_bundle_id(app_path):
    """Return CFBundleIdentifier for the given .app path, or empty string."""
    try:
        info = os.path.join(app_path, "Contents", "Info.plist")
        with open(info, 'rb') as f:
            return plistlib.load(f).get("CFBundleIdentifier", "")
    except Exception:
        return ""

def copy_space_assignment(src_app_path, clone_bundle_id, browser_app_path, dock_plist):
    try:
        src_bundle_id = _read_bundle_id(src_app_path)
        if not src_bundle_id:
            print("Space assignment skipped: source bundle-id not found")
            return

        # Try dock.plist first (explicit "Assign to desktop" action)
        assignments = dock_plist.get("workspaces-application-assignments", {})
        space_uuid = assignments.get(src_bundle_id)

        # Fallback: scan com.apple.spaces (Mission Control window placement)
        if not space_uuid:
            space_uuid = _find_space_uuid_in_spaces_plist(src_bundle_id)
            if space_uuid:
                print(f"Space UUID found via com.apple.spaces: {space_uuid}")

        if not space_uuid:
            print(f"Space assignment skipped: no Space pinning found for {src_bundle_id}")
            print("Tip: right-click the source app in Dock → Options → Assign to Desktop, then recreate the clone.")
            return

        # Assign the Space to our clone bundle-id
        assignments[clone_bundle_id] = space_uuid
        dock_plist["workspaces-application-assignments"] = assignments
        print(f"Space assignment: {src_bundle_id} → {clone_bundle_id} (Space {space_uuid})")

        # For PWA mode, write two files into the profile dir that the Swift
        # launcher reads on every click to enforce the Space pinning:
        #   * target_space_uuid — static UUID of the source app's Space at clone
        #     time. Used as the primary lookup; survives across reboots.
        #   * source_bundle_id — fallback for dynamic resolution. If the user
        #     moves Teams to a different Space later, the launcher uses this
        #     bundle-id to query com.apple.spaces and follow the move.
        # We never touch the browser's own Space assignment — Edge stays pinned
        # wherever the user set it.
        if browser_app_path:
            profile_dir = os.path.expanduser(
                f"~/Library/Application Support/AppCloner/{os.path.basename(app_path).removesuffix('.app')}_pwa"
            )
            os.makedirs(profile_dir, exist_ok=True)
            with open(os.path.join(profile_dir, "target_space_uuid"), 'w') as fh:
                fh.write(space_uuid)
            with open(os.path.join(profile_dir, "source_bundle_id"), 'w') as fh:
                fh.write(src_bundle_id)
            print(f"Space hint written: uuid={space_uuid}  source={src_bundle_id}")
    except Exception as e:
        print(f"Space assignment copy skipped ({e})")

copy_space_assignment(source_app, bundle_id, pwa_browser, dock)

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

# The very last line of stdout becomes the AppleScript `do shell script`
# return value, so we end with just the bundle path. The diagnostic file
# location is in the log itself if needed.
echo "$DEST"
