#!/usr/bin/env bash
# tools/build_macos_app.sh
#
# ==============================================================================
# MODULE: macOS .app builder
# DESCRIPTION:
# Assembles Ergopti.app — a self-contained macOS bundle that embeds a vendored
# Hammerspoon.app plus our entire Lua config tree, fronted by a Swift launcher
# (compiled from static/drivers/hammerspoon/launcher) that hosts Sparkle and
# spawns the embedded Hammerspoon under a rebranded bundle id.
#
# OUTPUT:
#  build/macos/Ergopti.app          — bundle ready to launch
#  build/macos/Ergopti.app.zip      — release asset (Sparkle expects a zip)
#  build/macos/appcast.xml-payload  — the <enclosure> snippet for the appcast,
#                                     emitted once the zip is signed below.
#
# REQUIREMENTS (runtime on the build host):
#  - macOS 13+ (build script runs on macos-latest GitHub runner)
#  - Xcode command-line tools (swift, codesign, iconutil, sips, plutil)
#  - curl, unzip, zip
#
# RATIONALE:
#  - The script is idempotent: every run wipes build/macos so the output is a
#    deterministic function of inputs. No incremental-build trickery.
#  - All version-stamping (CFBundleVersion, BUNDLE_VERSION, Sparkle key) goes
#    through env vars so the same script drives local dev builds and CI
#    releases without branching.
# ==============================================================================

set -euo pipefail




# ===========================================
# ===========================================
# ======= 1/ Configurable inputs ============
# ===========================================
# ===========================================

# Hammerspoon version pinned at the source of truth here. Bump in lock-step
# with any breaking API change observed in the Lua tree.
HAMMERSPOON_VERSION="${HAMMERSPOON_VERSION:-1.1.1}"

# Version stamped into the .app Info.plist. CI replaces it with the
# release-please-driven tag; local builds get a "dev" placeholder.
ERGOPTI_VERSION="${ERGOPTI_VERSION:-0.0.0-dev}"
ERGOPTI_BUILD="${ERGOPTI_BUILD:-1}"

# Sparkle update channel — used to pick between appcast-main.xml and
# appcast-dev.xml on the release host. Default is main; dev branch builds set
# this to "dev" via the CI workflow.
ERGOPTI_CHANNEL="${ERGOPTI_CHANNEL:-main}"

# Karabiner-Elements version bundled for key-remapping. The DMG is downloaded
# at build time and vendored inside Resources/Tools/ so users never need a
# separate download; the Lua driver opens the installer on first use if KE is
# not yet installed (a one-time system-extension approval is still required).
KARABINER_VERSION="${KARABINER_VERSION:-16.0.0}"

# Ollama CLI version bundled for local LLM inference. The universal binary is
# downloaded at build time and stored in Resources/Tools/ so the app can run
# local models on first launch without any manual install step. Users still
# need to pull a model the first time (models are multi-GB, not bundled).
OLLAMA_VERSION="${OLLAMA_VERSION:-0.24.0}"

# Sparkle EdDSA public key (base64). Empty string means "Sparkle will refuse
# to install updates"; CI must inject the real value from a secret.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

# GitHub repo coordinates so the appcast URL can be derived. Override via env.
GH_OWNER="${GH_OWNER:-Ergopti}"
GH_REPO="${GH_REPO:-Ergopti}"

# Bundle identifier for the embedded Hammerspoon. Picked so preferences land
# in ~/Library/Preferences/com.ergopti.app.plist, isolated from stock HS.
BUNDLE_ID="com.ergopti.app"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/macos"
APP_PATH="$BUILD_DIR/Ergopti.app"
ZIP_PATH="$BUILD_DIR/Ergopti.app.zip"
LAUNCHER_DIR="$REPO_ROOT/static/drivers/hammerspoon/launcher"




# ============================================
# ============================================
# ======= 2/ Helper functions ================
# ============================================
# ============================================

log()  { printf '[macos-build] %s\n' "$*"; }
fail() { printf '[macos-build] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

clean_build_dir() {
	log "Wiping $BUILD_DIR"
	rm -rf "$BUILD_DIR"
	mkdir -p "$BUILD_DIR"
}




# =================================================
# =================================================
# ======= 3/ Vendored Hammerspoon download ========
# =================================================
# =================================================

# Download and extract the pinned Hammerspoon release. We rely on the GitHub
# Releases asset rather than building from source: the release zip is signed
# by the Hammerspoon maintainers, includes all native dylibs, and pins us to
# a reproducible binary regardless of host SDK drift.
download_hammerspoon() {
	local cache_dir="$BUILD_DIR/cache"
	local zip="$cache_dir/Hammerspoon-$HAMMERSPOON_VERSION.zip"
	local url="https://github.com/Hammerspoon/hammerspoon/releases/download/$HAMMERSPOON_VERSION/Hammerspoon-$HAMMERSPOON_VERSION.zip"
	mkdir -p "$cache_dir"
	if [ ! -f "$zip" ]; then
		log "Downloading Hammerspoon $HAMMERSPOON_VERSION from $url"
		curl -sSfL "$url" -o "$zip" || fail "Hammerspoon download failed."
	else
		log "Using cached $zip"
	fi
	log "Extracting Hammerspoon into $BUILD_DIR"
	unzip -q "$zip" -d "$BUILD_DIR"
	[ -d "$BUILD_DIR/Hammerspoon.app" ] || fail "Hammerspoon.app not found after extraction."
}




# ==================================================
# ==================================================
# ======= 4/ Karabiner-Elements download ===========
# ==================================================
# ==================================================

# Download the Karabiner-Elements DMG and extract Karabiner-Elements.app so
# it can be vendored inside the bundle. Bundling the installer eliminates any
# runtime download; when the Lua driver first needs KE it detects whether it
# is installed, and if not, opens the bundled .app — the user then steps
# through the one-time system-extension approval prompt.
download_karabiner() {
	local cache_dir="$BUILD_DIR/cache"
	local dmg_name="Karabiner-Elements-$KARABINER_VERSION.dmg"
	local dmg_path="$cache_dir/$dmg_name"
	local ke_extracted="$BUILD_DIR/Karabiner-Elements.app"
	local url="https://github.com/pqrs-org/Karabiner-Elements/releases/download/v$KARABINER_VERSION/$dmg_name"
	mkdir -p "$cache_dir"
	if [ ! -f "$dmg_path" ]; then
		log "Downloading Karabiner-Elements $KARABINER_VERSION from $url"
		curl -sSfL "$url" -o "$dmg_path" || fail "Karabiner-Elements download failed."
	else
		log "Using cached $dmg_path"
	fi
	if [ ! -d "$ke_extracted" ]; then
		log "Extracting Karabiner-Elements.app from DMG"
		local mount_point
		mount_point="$(mktemp -d)"
		log "DMG path: $dmg_path (size: $(wc -c < "$dmg_path") bytes)"
		local plist_out
		plist_out="$(echo y | hdiutil attach "$dmg_path" -nobrowse -noverify -plist 2>/dev/null)" \
			|| fail "hdiutil attach failed."
		local actual_mount
		actual_mount="$(echo "$plist_out" | python3 -c "
import sys, plistlib
p = plistlib.loads(sys.stdin.buffer.read())
for e in p.get('system-entities', []):
    mp = e.get('mount-point')
    if mp:
        print(mp)
" | tail -1)"
		log "Detected mount: '$actual_mount'"
		[ -n "$actual_mount" ] || fail "Could not detect mount point from hdiutil plist output."
		log "DMG contents:"
		find "$actual_mount" -maxdepth 5 2>&1 | head -60 | while IFS= read -r line; do log "  $line"; done
		local ke_in_dmg
		ke_in_dmg="$(find "$actual_mount" -maxdepth 5 \( -name "*.app" -o -name "*.pkg" \) | head -1)"
		[ -n "$ke_in_dmg" ] \
			|| fail "No .app or .pkg found in DMG at $actual_mount."
		log "Found app: $ke_in_dmg"
		cp -R "$ke_in_dmg" "$ke_extracted"
		hdiutil detach "$actual_mount" -quiet || true
		rmdir "$mount_point" 2>/dev/null || true
	fi
	[ -d "$ke_extracted" ] || fail "Karabiner-Elements.app not extracted."
	echo "$ke_extracted"
}




# ==================================================
# ==================================================
# ======= 5/ Ollama download =======================
# ==================================================
# ==================================================

# Download the pinned Ollama universal binary (amd64 + arm64) for macOS.
# Vendoring the binary inside Resources/Tools/ means local LLM inference works
# out-of-the-box; models are still pulled on demand by the user (they are
# multi-GB and cannot be bundled).
download_ollama() {
	local cache_dir="$BUILD_DIR/cache"
	local bin_name="ollama-darwin-$OLLAMA_VERSION"
	local bin_path="$cache_dir/$bin_name"
	local url="https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-darwin"
	mkdir -p "$cache_dir"
	if [ ! -f "$bin_path" ]; then
		log "Downloading Ollama $OLLAMA_VERSION from $url"
		curl -sSfL "$url" -o "$bin_path" || fail "Ollama download failed."
		chmod +x "$bin_path"
	else
		log "Using cached $bin_path"
	fi
	[ -f "$bin_path" ] || fail "Ollama binary not found after download."
	echo "$bin_path"
}




# =====================================================
# =====================================================
# ======= 6/ Swift launcher compilation ==============
# =====================================================
# =====================================================

# Build the launcher with the official Swift toolchain. We compile in release
# mode for size + speed; the binary then gets relocated into Contents/MacOS.
build_launcher() {
	log "Building Swift launcher (release)"
	(
		cd "$LAUNCHER_DIR"
		swift build -c release --product Ergopti
	)
	local built_bin
	built_bin="$(cd "$LAUNCHER_DIR" && swift build -c release --show-bin-path)/Ergopti"
	[ -f "$built_bin" ] || fail "Swift build did not produce Ergopti binary."
	echo "$built_bin"
}




# ====================================================
# ====================================================
# ======= 7/ App bundle assembly =====================
# ====================================================
# ====================================================

# Assemble the Ergopti.app skeleton, copy the launcher + Hammerspoon, drop our
# Lua config into Resources/config/, and stamp Info.plist. The embedded
# Hammerspoon's bundle id is rewritten so its preferences land under our id.
assemble_app() {
	local launcher_bin="$1"
	local ke_app_path="$2"
	local ollama_bin_path="$3"
	log "Assembling $APP_PATH"
	mkdir -p "$APP_PATH/Contents/MacOS"
	mkdir -p "$APP_PATH/Contents/Resources/config"
	mkdir -p "$APP_PATH/Contents/Frameworks"

	# Move the downloaded Hammerspoon into Frameworks/. We move (not copy) to
	# keep the build dir small and to avoid duplicating ~250 MB.
	mv "$BUILD_DIR/Hammerspoon.app" "$APP_PATH/Contents/Frameworks/Hammerspoon.app"

	# Rewrite the embedded Hammerspoon's bundle id so its NSUserDefaults land
	# under com.ergopti.app — the launcher reads/writes MJConfigDir there.
	# Without this rewrite a stock Hammerspoon install on the same machine
	# would share its preferences with our embedded instance and overwrite
	# the config-dir override on every launch.
	local hs_plist="$APP_PATH/Contents/Frameworks/Hammerspoon.app/Contents/Info.plist"
	[ -f "$hs_plist" ] || fail "embedded Hammerspoon Info.plist missing."
	plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$hs_plist"

	# Disarm the embedded Hammerspoon's own Sparkle so it never tries to
	# update itself behind our back. Updates are owned exclusively by the
	# launcher's Sparkle instance, which targets the Ergopti release feed.
	plutil -remove SUFeedURL "$hs_plist" 2>/dev/null || true
	plutil -replace SUEnableAutomaticChecks -bool false "$hs_plist"

	# Copy the launcher binary into the standard host-executable location.
	cp "$launcher_bin" "$APP_PATH/Contents/MacOS/Ergopti"
	chmod +x "$APP_PATH/Contents/MacOS/Ergopti"

	# Mirror the dev tree under Contents/Resources/ so every Lua path that
	# walks up from hs.configdir (e.g. ``hs.configdir .. "/../_shared/..."``,
	# ``locale.lua``'s gsub("/static/drivers/hammerspoon$"), etc.) resolves
	# correctly without any code change. The MJConfigDir we point Hammerspoon
	# at is the embedded ``static/drivers/hammerspoon`` subtree.
	local res="$APP_PATH/Contents/Resources"
	local static_root="$res/static"
	mkdir -p "$static_root/drivers"

	# Lua config tree — what Hammerspoon will load. Exclude dev-only paths.
	rsync -a \
		--exclude='.venv' \
		--exclude='.pytest_cache' \
		--exclude='tests' \
		--exclude='paths.toml' \
		--exclude='launcher' \
		"$REPO_ROOT/static/drivers/hammerspoon/" \
		"$static_root/drivers/hammerspoon/"

	# Sibling _shared/ tree (WebView HTML/CSS/JS, LLM defaults, DB schema).
	cp -R "$REPO_ROOT/static/drivers/_shared"     "$static_root/drivers/_shared"

	# Static assets at the repo's static/ root.
	cp -R "$REPO_ROOT/static/menu_manifest.json"  "$static_root/"
	cp -R "$REPO_ROOT/static/version.json"        "$static_root/" 2>/dev/null || true
	cp -R "$REPO_ROOT/static/locales"             "$static_root/"
	cp -R "$REPO_ROOT/static/hotstrings"          "$static_root/"
	cp -R "$REPO_ROOT/static/img"                 "$static_root/"
	cp -R "$REPO_ROOT/static/shared"              "$static_root/"

	# Bundle third-party tools so they are available on first launch with no
	# runtime download. KE remains an installer app (a one-time system-extension
	# approval prompt is unavoidable); Ollama is the CLI server binary and runs
	# directly — models are pulled on demand.
	local tools_dir="$APP_PATH/Contents/Resources/Tools"
	mkdir -p "$tools_dir/Karabiner"
	mkdir -p "$tools_dir/Ollama"
	log "Bundling Karabiner-Elements $KARABINER_VERSION"
	cp -R "$ke_app_path" "$tools_dir/Karabiner/Karabiner-Elements.app"
	log "Bundling Ollama $OLLAMA_VERSION"
	cp "$ollama_bin_path" "$tools_dir/Ollama/ollama"
	chmod +x "$tools_dir/Ollama/ollama"
}




# ===========================================
# ===========================================
# ======= 8/ Icon generation ================
# ===========================================
# ===========================================

# Convert the existing logo PNG into a .icns icon set. iconutil only accepts
# a .iconset folder containing multiple sizes named per Apple's convention,
# so we synthesize them with sips on the fly.
build_icon() {
	log "Generating Ergopti.icns from logo_simple_square.png"
	local src="$REPO_ROOT/static/img/logo/logo_simple_square.png"
	[ -f "$src" ] || fail "icon source missing: $src"
	local iconset="$BUILD_DIR/Ergopti.iconset"
	rm -rf "$iconset"
	mkdir -p "$iconset"
	# Apple wants @1x and @2x for each of 16, 32, 128, 256, 512 pixel sizes.
	for size in 16 32 128 256 512; do
		sips -z "$size" "$size"   "$src" --out "$iconset/icon_${size}x${size}.png"     >/dev/null
		double=$((size * 2))
		sips -z "$double" "$double" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$iconset" -o "$APP_PATH/Contents/Resources/Ergopti.icns"
}




# =====================================================
# =====================================================
# ======= 9/ Info.plist generation ====================
# =====================================================
# =====================================================

# Build the launcher's Info.plist from scratch via plutil. Doing it here
# (rather than via a static template + sed) keeps every key visible in one
# place and avoids the template-with-secrets-in-it antipattern.
generate_info_plist() {
	local plist="$APP_PATH/Contents/Info.plist"
	log "Generating $plist"
	cat > "$plist" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>CFBundleName</key>                   <string>Ergopti</string>
			<key>CFBundleDisplayName</key>            <string>Ergopti</string>
			<key>CFBundleExecutable</key>             <string>Ergopti</string>
			<key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
			<key>CFBundlePackageType</key>            <string>APPL</string>
			<key>CFBundleShortVersionString</key>     <string>$ERGOPTI_VERSION</string>
			<key>CFBundleVersion</key>                <string>$ERGOPTI_BUILD</string>
			<key>CFBundleIconFile</key>               <string>Ergopti</string>
			<key>LSMinimumSystemVersion</key>         <string>11.0</string>
			<key>LSUIElement</key>                    <false/>
			<key>NSHighResolutionCapable</key>        <true/>
			<key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
			<key>NSPrincipalClass</key>               <string>NSApplication</string>

			<!-- Sparkle wiring. SUFeedURL points at a channel-scoped appcast
			     hosted on GitHub Releases. SUPublicEDKey must match the
			     private key the CI signing step uses. -->
			<key>SUFeedURL</key>                      <string>https://github.com/$GH_OWNER/$GH_REPO/releases/latest/download/appcast-$ERGOPTI_CHANNEL.xml</string>
			<key>SUPublicEDKey</key>                  <string>$SPARKLE_PUBLIC_KEY</string>
			<key>SUEnableAutomaticChecks</key>        <true/>
			<key>SUScheduledCheckInterval</key>       <integer>86400</integer>
			<key>SUAllowsAutomaticUpdates</key>       <true/>
		</dict>
		</plist>
	PLIST
	plutil -lint "$plist" >/dev/null || fail "Generated Info.plist failed plutil -lint."
}




# ===============================================
# ===============================================
# ======= 10/ Codesign + zip ====================
# ===============================================
# ===============================================

# Ad-hoc sign so Gatekeeper at least stops complaining about an unsigned
# binary. A real Developer ID signature comes in Phase 5; for now the user
# will see a one-time "developer cannot be verified" prompt on first launch.
codesign_app() {
	log "Codesigning Ergopti.app (ad-hoc)"
	# Sign nested .app bundles first so the host-level --deep pass finds them
	# already valid rather than re-signing them in an undefined order.
	codesign --force --deep --sign - "$APP_PATH/Contents/Frameworks/Hammerspoon.app"
	codesign --force --deep --sign - "$APP_PATH/Contents/Resources/Tools/Karabiner/Karabiner-Elements.app"
	codesign --force --sign - "$APP_PATH/Contents/MacOS/Ergopti"
	codesign --force --deep --sign - "$APP_PATH"
}

# Zip the bundle as a release artefact. Sparkle expects a zip whose top-level
# entry is the .app itself (no extra wrapping directory).
zip_app() {
	log "Zipping $APP_PATH → $ZIP_PATH"
	(cd "$BUILD_DIR" && zip -qry "$(basename "$ZIP_PATH")" "$(basename "$APP_PATH")")
	[ -f "$ZIP_PATH" ] || fail "zip did not produce expected output."
}




# ==========================================
# ==========================================
# ======= 11/ Entrypoint ===================
# ==========================================
# ==========================================

main() {
	for cmd in curl unzip zip swift codesign iconutil sips plutil rsync hdiutil; do
		require_cmd "$cmd"
	done

	clean_build_dir
	download_hammerspoon
	local launcher_bin
	launcher_bin="$(build_launcher)"
	local ke_app_path
	ke_app_path="$(download_karabiner)"
	local ollama_bin_path
	ollama_bin_path="$(download_ollama)"
	assemble_app "$launcher_bin" "$ke_app_path" "$ollama_bin_path"
	build_icon
	generate_info_plist
	codesign_app
	zip_app

	log "Done."
	log "  bundle     : $APP_PATH"
	log "  zip        : $ZIP_PATH"
	log "  version    : $ERGOPTI_VERSION ($ERGOPTI_BUILD)"
	log "  channel    : $ERGOPTI_CHANNEL"
	log "  hammerspoon: $HAMMERSPOON_VERSION"
	log "  karabiner  : $KARABINER_VERSION"
	log "  ollama     : $OLLAMA_VERSION"
}

main "$@"
