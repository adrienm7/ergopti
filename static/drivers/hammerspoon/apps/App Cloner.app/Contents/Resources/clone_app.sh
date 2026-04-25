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

log "============================================================"
log "=== AppCloner (stub mode) — $(date)"
log "=== SOURCE=$SOURCE_APP"
log "=== NAME=$CLONE_NAME  COLOR=$COLOR_HEX  ARG=$OPEN_ARG"
log "=== ICON_MODE=$ICON_MODE  ICON_PATH=$ICON_PATH  PWA=$PWA_MODE"
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
		# Convert anything else to a 1024-square PNG. sips silently scales+pads.
		sips -s format png -z 1024 1024 "$ICON_PATH" --out "$BASE_PNG" >/dev/null 2>&1 || true
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
	# Locate a Chromium-based browser. Edge is preferred (best Teams /
	# Microsoft 365 integration), Chrome and Brave are accepted fallbacks.
	PWA_BROWSER=""
	for candidate in \
		"/Applications/Microsoft Edge.app" \
		"$HOME/Applications/Microsoft Edge.app" \
		"/Applications/Google Chrome.app" \
		"$HOME/Applications/Google Chrome.app" \
		"/Applications/Brave Browser.app" \
		"$HOME/Applications/Brave Browser.app"; do
		if [[ -d "$candidate" ]]; then
			PWA_BROWSER="$candidate"
			break
		fi
	done
	if [[ -z "$PWA_BROWSER" ]]; then
		echo "Error: PWA mode requires Microsoft Edge, Google Chrome or Brave installed in /Applications."
		exit 1
	fi
	PWA_BROWSER_EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PWA_BROWSER/Contents/Info.plist" 2>/dev/null || echo "")"
	PWA_BROWSER_EXE="$PWA_BROWSER/Contents/MacOS/$PWA_BROWSER_EXE_NAME"
	log "PWA browser: $PWA_BROWSER_EXE"

	# Per-clone Chromium profile — keeps cookies/storage/extensions of each
	# PWA fully isolated from the user's main browser and from other PWAs.
	PWA_PROFILE_DIR="$HOME/Library/Application Support/AppCloner/${safe_name}_pwa"
	mkdir -p "$PWA_PROFILE_DIR"

	# Compile a real Cocoa NSApplication launcher in Swift. This is the only
	# reliable singleton mechanism for an .app bundle: macOS guarantees a single
	# NSApplication instance per bundle-id and dispatches kAEReopenApplication
	# events to it. A shell or Python script cannot intercept those events.
	#
	# The launcher also moves Edge windows to the target Space via the private
	# CGSMoveWindowsToManagedSpace API — this overrides Edge's own Space pinning
	# (Edge may be pinned to Space 1, but the cloned PWA window must land on
	# the source app's Space, e.g. Teams' Space 2).
	#
	# We use a heredoc without quoting so shell expands ${PWA_PROFILE_DIR},
	# ${PWA_BROWSER_EXE}, ${OPEN_ARG}, ${UNIQUE_ID} into the Swift source.
	# Swift's string interpolation uses \(...) which the shell preserves verbatim.
	SWIFT_SRC="$RES/launcher.swift"
	cat > "$SWIFT_SRC" << SWIFTEOF
import Cocoa
import Foundation
import CoreGraphics

let PROFILE_DIR = "${PWA_PROFILE_DIR}"
let BROWSER_EXE = "${PWA_BROWSER_EXE}"
let OPEN_ARG    = "${OPEN_ARG}"
let UNIQUE_ID   = "${UNIQUE_ID}"
let LOG_FILE    = "/tmp/appcloner_pwa_\(UNIQUE_ID).log"
let SPACE_HINT  = (PROFILE_DIR as NSString).appendingPathComponent("target_space_uuid")

// Private CoreGraphics Services APIs for Space management.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: Int32, _ mask: Int) -> CFArray?

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ wids: CFArray, _ sid: Int)

// Look up the macOS-internal Space ID for a Space UUID stored in com.apple.spaces.
func spaceID(forUUID uuid: String) -> Int? {
	let cid = CGSMainConnectionID()
	guard let raw = CGSCopySpaces(cid, 0xF) as? [[String: Any]] else { return nil }
	for entry in raw {
		if let u = entry["uuid"] as? String, u == uuid,
		   let sid = entry["ManagedSpaceID"] as? Int { return sid }
	}
	return nil
}

// Find an Edge process already using our profile dir. Used to recover from
// orphaned Edge instances after a launcher crash, so we never spawn a duplicate.
func findEdgePID() -> pid_t? {
	let task = Process()
	task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
	task.arguments = ["-f", "user-data-dir=\(PROFILE_DIR)"]
	let pipe = Pipe()
	task.standardOutput = pipe
	task.standardError = Pipe()
	do { try task.run() } catch { return nil }
	task.waitUntilExit()
	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	guard let s = String(data: data, encoding: .utf8) else { return nil }
	return s.split(separator: "\n")
		.compactMap { pid_t(\$0.trimmingCharacters(in: .whitespaces)) }
		.first
}

class AppDelegate: NSObject, NSApplicationDelegate {
	var edgeProcess: Process?
	var edgePID: pid_t = 0

	func applicationDidFinishLaunching(_ notification: Notification) {
		try? FileManager.default.createDirectory(
			atPath: PROFILE_DIR, withIntermediateDirectories: true
		)

		// Recovery path: orphaned Edge from a previous crashed launcher. Adopt
		// it instead of spawning a second instance (which would open a new
		// browser tab via Edge's IPC SingletonSocket).
		if let pid = findEdgePID() {
			edgePID = pid
			NSRunningApplication(processIdentifier: pid)?.activate(
				options: [.activateAllWindows, .activateIgnoringOtherApps]
			)
			// Watch the orphan; when it dies, we die too.
			DispatchQueue.global(qos: .background).async {
				while kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 1.0) }
				DispatchQueue.main.async { NSApp.terminate(nil) }
			}
			return
		}

		// Read the Space hint written at clone-creation time. Consumed once
		// on first launch, then deleted (subsequent launches let Edge remember
		// its own window position).
		var targetSpaceID: Int? = nil
		if FileManager.default.fileExists(atPath: SPACE_HINT) {
			if let raw = try? String(contentsOfFile: SPACE_HINT, encoding: .utf8) {
				let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
				targetSpaceID = spaceID(forUUID: trimmed)
			}
			try? FileManager.default.removeItem(atPath: SPACE_HINT)
		}

		// Launch Edge as a child process. __CFBundleIdentifier overrides Edge's
		// own bundle-id so LaunchServices registers Edge under our clone's id —
		// this prevents a duplicate Edge tile from appearing in the Dock alongside
		// our cloned-app tile.
		let p = Process()
		p.executableURL = URL(fileURLWithPath: BROWSER_EXE)
		p.arguments = [
			"--app=\(OPEN_ARG)",
			"--user-data-dir=\(PROFILE_DIR)",
			"--no-first-run",
			"--no-default-browser-check",
			"--disable-features=DesktopPWAsLinkCapturing,WebAppEnableUrlHandling",
			"--disable-default-apps",
		]
		var env = ProcessInfo.processInfo.environment
		env["__CFBundleIdentifier"] = UNIQUE_ID
		p.environment = env

		if !FileManager.default.fileExists(atPath: LOG_FILE) {
			FileManager.default.createFile(atPath: LOG_FILE, contents: nil)
		}
		if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: LOG_FILE)) {
			h.seekToEndOfFile()
			p.standardOutput = h
			p.standardError = h
		}

		// When Edge exits, the launcher exits too — keeps the Dock tile lifecycle in sync.
		p.terminationHandler = { _ in
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}

		do {
			try p.run()
			edgeProcess = p
			edgePID = p.processIdentifier
		} catch {
			NSApp.terminate(nil)
			return
		}

		// Move Edge's PWA window to the target Space once it appears. This overrides
		// Edge's own Space pinning — the user's Edge stays on Space 1, but our cloned
		// PWA window goes to Space 2 (Teams' Space). Polled because the window may
		// take a moment to render after Edge starts.
		if let sid = targetSpaceID {
			let pid = edgePID
			DispatchQueue.global(qos: .background).async {
				for _ in 0..<60 {
					Thread.sleep(forTimeInterval: 0.1)
					let cid = CGSMainConnectionID()
					guard let info = CGWindowListCopyWindowInfo(
						[.optionAll], kCGNullWindowID
					) as? [[String: Any]] else { continue }
					let wids = info.compactMap { d -> Int? in
						guard let owner = d[kCGWindowOwnerPID as String] as? Int,
						      owner == Int(pid),
						      let layer = d[kCGWindowLayer as String] as? Int,
						      layer == 0,
						      let num = d[kCGWindowNumber as String] as? Int
						else { return nil }
						return num
					}
					if !wids.isEmpty {
						CGSMoveWindowsToManagedSpace(cid, wids as CFArray, sid)
						DispatchQueue.main.async {
							NSRunningApplication(processIdentifier: pid)?.activate(
								options: [.activateAllWindows, .activateIgnoringOtherApps]
							)
						}
						break
					}
				}
			}
		}
	}

	// Dock click while we are running — focus Edge, never spawn a new instance.
	// This is THE method that fixes the singleton issue: macOS sends this event
	// instead of relaunching the binary, so there is exactly one Edge child ever.
	func applicationShouldHandleReopen(
		_ sender: NSApplication, hasVisibleWindows flag: Bool
	) -> Bool {
		if edgePID > 0 {
			NSRunningApplication(processIdentifier: edgePID)?.activate(
				options: [.activateAllWindows, .activateIgnoringOtherApps]
			)
		}
		return true
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		return false
	}

	func applicationWillTerminate(_ notification: Notification) {
		// Only terminate Edge if we spawned it (not if we adopted an orphan).
		edgeProcess?.terminate()
	}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFTEOF

	# Compile the Swift launcher to a Mach-O binary. Falls back to script mode
	# (#!/usr/bin/env swift) if swiftc is missing — slower startup but works.
	if command -v swiftc >/dev/null 2>&1; then
		if swiftc "$SWIFT_SRC" -o "$LAUNCHER" \
		         -framework Cocoa -framework CoreGraphics 2>>"$DIAG"; then
			log "Swift launcher compiled to native binary"
		else
			log "WARNING: swiftc failed — falling back to swift script mode"
			{ echo "#!/usr/bin/env swift"; cat "$SWIFT_SRC"; } > "$LAUNCHER"
		fi
	else
		log "swiftc not found — using swift script mode (install Xcode CLI tools for faster startup)"
		{ echo "#!/usr/bin/env swift"; cat "$SWIFT_SRC"; } > "$LAUNCHER"
	fi
	chmod +x "$LAUNCHER"
	log "PWA launcher written → ${PWA_BROWSER_EXE} --app=${OPEN_ARG}"
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

        # For PWA mode, we also write the Space UUID to a file in the PWA
        # profile dir. The launcher reads it at startup, switches to that Space
        # (so Edge opens there naturally), then removes it after first use —
        # subsequent launches rely on the browser's own last-position memory.
        # We never touch the browser's own Space assignment (it may already be
        # pinned to a different Space by the user and we must not override it).
        if browser_app_path:
            profile_dir = os.path.expanduser(
                f"~/Library/Application Support/AppCloner/{os.path.basename(app_path).removesuffix('.app')}_pwa"
            )
            os.makedirs(profile_dir, exist_ok=True)
            space_hint = os.path.join(profile_dir, "target_space_uuid")
            with open(space_hint, 'w') as fh:
                fh.write(space_uuid)
            print(f"Space hint written to {space_hint}")
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
