#!/usr/bin/env bash
# tools/build_macos_app.sh
#
# ==============================================================================
# MODULE: macOS .app builder
# DESCRIPTION:
# Assembles Ergopti.app — a self-contained macOS bundle that embeds a vendored
# Hammerspoon.app plus our entire Lua config tree, fronted by a Swift launcher
# (compiled from static/ergopti_plus/macos/launcher) that hosts Sparkle and
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

# The outer app prohibits duplicate instances. Give the embedded GUI runtime a
# dedicated Ergopti-owned identity while keeping it isolated from stock HS.
BUNDLE_ID="com.ergoptiplus.app"
HAMMERSPOON_BUNDLE_ID="com.ergoptiplus.app.hammerspoon"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/macos"
APP_PATH="$BUILD_DIR/ErgoptiPlus.app"
ZIP_PATH="$BUILD_DIR/ErgoptiPlus.app.zip"
LAUNCHER_DIR="$REPO_ROOT/static/ergopti_plus/macos/launcher"




# ============================================
# ============================================
# ======= 2/ Helper functions ================
# ============================================
# ============================================

log()  { printf '[macos-build] %s\n' "$*" >&2; }
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
	local ke_extracted="$BUILD_DIR/Karabiner-Elements"
	local url="https://github.com/pqrs-org/Karabiner-Elements/releases/download/v$KARABINER_VERSION/$dmg_name"
	mkdir -p "$cache_dir"
	if [ ! -f "$dmg_path" ]; then
		log "Downloading Karabiner-Elements $KARABINER_VERSION from $url"
		curl -sSfL "$url" -o "$dmg_path" || fail "Karabiner-Elements download failed."
	else
		log "Using cached $dmg_path"
	fi
	if [ ! -e "$ke_extracted" ]; then
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
		local ke_src_ext="${ke_in_dmg##*.}"
		log "Found: $ke_in_dmg (ext: $ke_src_ext)"
		cp -R "$ke_in_dmg" "$ke_extracted.$ke_src_ext"
		ln -sf "$ke_extracted.$ke_src_ext" "$ke_extracted"
		hdiutil detach "$actual_mount" -quiet || true
		rmdir "$mount_point" 2>/dev/null || true
	fi
	[ -e "$ke_extracted" ] || fail "Karabiner-Elements not extracted."
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
	local tgz_name="ollama-darwin-$OLLAMA_VERSION.tgz"
	local tgz_path="$cache_dir/$tgz_name"
	local bin_path="$cache_dir/ollama-darwin-$OLLAMA_VERSION"
	local url="https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-darwin.tgz"
	mkdir -p "$cache_dir"
	if [ ! -f "$bin_path" ]; then
		log "Downloading Ollama $OLLAMA_VERSION from $url"
		curl -sSfL "$url" -o "$tgz_path" || fail "Ollama download failed."
		tar -xzf "$tgz_path" -C "$cache_dir" --strip-components=0 2>/dev/null || true
		# The tgz contains a single binary named "ollama"
		[ -f "$cache_dir/ollama" ] && mv "$cache_dir/ollama" "$bin_path"
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
		swift build -c release --product ErgoptiPlus >&2
	)
	local built_bin
	built_bin="$(find "$LAUNCHER_DIR/.build" -name "ErgoptiPlus" -type f -path "*/release/ErgoptiPlus" | head -1)"
	[ -f "$built_bin" ] || fail "Swift build did not produce ErgoptiPlus binary."
	log "Launcher binary: $built_bin"
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
	mkdir -p "$APP_PATH/Contents/Library/LaunchAgents"

	# Move the downloaded Hammerspoon into Frameworks/. We move (not copy) to
	# keep the build dir small and to avoid duplicating ~250 MB.
	mv "$BUILD_DIR/Hammerspoon.app" "$APP_PATH/Contents/Frameworks/Hammerspoon.app"

	# Rewrite the embedded Hammerspoon's bundle id so its NSUserDefaults land
	# under the dedicated child identity used by the launcher's CFPreferences.
	# Without this rewrite a stock Hammerspoon install on the same machine
	# would share its preferences with our embedded instance and overwrite
	# the config-dir override on every launch.
	local hs_plist="$APP_PATH/Contents/Frameworks/Hammerspoon.app/Contents/Info.plist"
	[ -f "$hs_plist" ] || fail "embedded Hammerspoon Info.plist missing."
	plutil -replace CFBundleIdentifier -string "$HAMMERSPOON_BUNDLE_ID" "$hs_plist"

	# Disarm the embedded Hammerspoon's own Sparkle so it never tries to
	# update itself behind our back. Updates are owned exclusively by the
	# launcher's Sparkle instance, which targets the Ergopti release feed.
	plutil -remove SUFeedURL "$hs_plist" 2>/dev/null || true
	plutil -replace SUEnableAutomaticChecks -bool false "$hs_plist"

	# Copy the launcher binary into the standard host-executable location.
	cp "$launcher_bin" "$APP_PATH/Contents/MacOS/ErgoptiPlus"
	chmod +x "$APP_PATH/Contents/MacOS/ErgoptiPlus"
	local remap_guardian_plist="$LAUNCHER_DIR/com.ergoptiplus.remap-guardian.plist"
	[ -f "$remap_guardian_plist" ] || fail "Remap guardian LaunchAgent plist missing."
	cp "$remap_guardian_plist" \
		"$APP_PATH/Contents/Library/LaunchAgents/com.ergoptiplus.remap-guardian.plist"
	plutil -lint \
		"$APP_PATH/Contents/Library/LaunchAgents/com.ergoptiplus.remap-guardian.plist" \
		>/dev/null || fail "Remap guardian LaunchAgent plist failed plutil -lint."

	# Copy Sparkle.framework into Contents/Frameworks/. The launcher links
	# against Sparkle via @rpath, and the SPM build leaves the framework in
	# .build/artifacts/<package>/Sparkle/Sparkle.framework rather than next
	# to the binary — without this step dyld fails with "Library not loaded:
	# @rpath/Sparkle.framework/Versions/B/Sparkle" at launch.
	# SPM can place the extracted Sparkle.framework in different locations
	# depending on the Sparkle package type (binary XCFramework vs source):
	#   - .build/artifacts/**  (binary target, SPM 5.6+)
	#   - .build/checkouts/**  (source build)
	#   - .build/release/     (copied next to product by some SPM versions)
	# We prefer the macOS slice from the XCFramework when present, then fall back
	# to any Sparkle.framework found anywhere under .build.
	local sparkle_fw
	sparkle_fw="$(find "$LAUNCHER_DIR/.build/artifacts" -name "Sparkle.framework" -type d 2>/dev/null | grep -i "macos" | head -1)"
	if [ -z "$sparkle_fw" ]; then
		sparkle_fw="$(find "$LAUNCHER_DIR/.build/artifacts" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
	fi
	if [ -z "$sparkle_fw" ]; then
		sparkle_fw="$(find "$LAUNCHER_DIR/.build" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
	fi
	[ -n "$sparkle_fw" ] || fail "Sparkle.framework not found under $LAUNCHER_DIR/.build — run 'swift build' in $LAUNCHER_DIR first."
	log "Bundling Sparkle.framework (source: $sparkle_fw)"
	cp -R "$sparkle_fw" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

	# Mirror the dev tree under Contents/Resources/ at the SAME repo-relative
	# layout (static/ergopti_plus/...) so every Lua path resolves identically in
	# the bundle and in a dev checkout — hs.configdir-relative walks,
	# ``locale.lua``'s gsub("/static/ergopti_plus/macos$"), models_manager_mlx's
	# project_root + "/static/ergopti_plus/macos", etc. — with no code change.
	# The MJConfigDir we point Hammerspoon at is the embedded
	# ``static/ergopti_plus/macos`` subtree.
	local res="$APP_PATH/Contents/Resources"
	local static_root="$res/static"
	mkdir -p "$static_root/ergopti_plus"

	# Lua config tree — what Hammerspoon will load. Exclude dev-only paths.
	rsync -a \
		--exclude='.venv' \
		--exclude='.pytest_cache' \
		--exclude='tests' \
		--exclude='paths.toml' \
		--exclude='launcher' \
		"$REPO_ROOT/static/ergopti_plus/macos/" \
		"$static_root/ergopti_plus/macos/"

	# Shared tree (WebView HTML/CSS/JS, LLM defaults, DB schema, locales, hotstrings).
	cp -R "$REPO_ROOT/static/ergopti_plus/_shared"      "$static_root/ergopti_plus/_shared"

	# Static assets.
	cp -R "$REPO_ROOT/static/ergopti_plus/_shared/modules/menu/menu_manifest.json" "$static_root/"
	cp -R "$REPO_ROOT/static/version.json"        "$static_root/" 2>/dev/null || true
	cp -R "$REPO_ROOT/static/ergopti_plus/_shared/data/locales"            "$static_root/"
	cp -R "$REPO_ROOT/static/ergopti_plus/_shared/modules/hotstrings"         "$static_root/"
	cp -R "$REPO_ROOT/static/img"                 "$static_root/"

	# Bundle third-party tools so they are available on first launch with no
	# runtime download. KE remains an installer app (a one-time system-extension
	# approval prompt is unavoidable); Ollama is the CLI server binary and runs
	# directly — models are pulled on demand.
	local tools_dir="$APP_PATH/Contents/Resources/Tools"
	mkdir -p "$tools_dir/Karabiner"
	mkdir -p "$tools_dir/Ollama"
	local ke_real
	ke_real="$(readlink "$ke_app_path" 2>/dev/null || echo "$ke_app_path")"
	local ke_ext="${ke_real##*.}"
	log "Bundling Karabiner-Elements $KARABINER_VERSION (source: $ke_real ext: $ke_ext)"
	cp -R "$ke_real" "$tools_dir/Karabiner/Karabiner-Elements.$ke_ext"
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
	log "Generating ErgoptiPlus.icns from logo_simple_square.png"
	local src="$REPO_ROOT/static/img/logo/logo_simple_square.png"
	[ -f "$src" ] || fail "icon source missing: $src"
	local iconset="$BUILD_DIR/ErgoptiPlus.iconset"
	rm -rf "$iconset"
	mkdir -p "$iconset"
	# Apple wants @1x and @2x for each of 16, 32, 128, 256, 512 pixel sizes.
	for size in 16 32 128 256 512; do
		sips -z "$size" "$size"   "$src" --out "$iconset/icon_${size}x${size}.png"     >/dev/null
		double=$((size * 2))
		sips -z "$double" "$double" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$iconset" -o "$APP_PATH/Contents/Resources/ErgoptiPlus.icns"
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
			<key>CFBundleName</key>                   <string>ErgoptiPlus</string>
			<key>CFBundleDisplayName</key>            <string>ErgoptiPlus</string>
			<key>CFBundleExecutable</key>             <string>ErgoptiPlus</string>
			<key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
			<key>CFBundlePackageType</key>            <string>APPL</string>
			<key>CFBundleShortVersionString</key>     <string>$ERGOPTI_VERSION</string>
			<key>CFBundleVersion</key>                <string>$ERGOPTI_BUILD</string>
			<key>CFBundleIconFile</key>               <string>ErgoptiPlus</string>
			<key>LSMinimumSystemVersion</key>         <string>11.0</string>
			<key>LSUIElement</key>                    <false/>
			<key>LSMultipleInstancesProhibited</key>  <true/>
			<key>NSHighResolutionCapable</key>        <true/>
			<key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
			<key>NSPrincipalClass</key>               <string>NSApplication</string>
			<key>CFBundleURLTypes</key>
			<array>
				<dict>
					<key>CFBundleURLName</key>           <string>com.ergoptiplus.app.updater</string>
					<key>CFBundleURLSchemes</key>
					<array><string>ergoptiplus</string></array>
				</dict>
			</array>

			<!-- Sparkle wiring. SUFeedURL points at a channel-scoped appcast
			     hosted on GitHub Releases. SUPublicEDKey must match the
			     private key the CI signing step uses. -->
			<key>SUFeedURL</key>                      <string>https://github.com/$GH_OWNER/$GH_REPO/releases/download/sparkle-feed/appcast-$ERGOPTI_CHANNEL.xml</string>
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

# Sign the app ad-hoc but with an explicit --identifier anchored to the bundle
# ID. Without --identifier, ad-hoc signing uses the binary hash as the
# identity — a hash that changes on every build — which causes macOS TCC to
# treat each new build as an unknown app and re-prompt for Accessibility /
# Input Monitoring permissions. Pinning the identifier to the stable bundle ID
# makes TCC recognise every build as the same app, so granted permissions
# survive updates (as long as the user installs over the same path).
#
# The entitlements file is included so the launcher binary carries an explicit
# com.apple.security.automation.apple-events claim. Without it some macOS
# versions pop an extra automation-permission dialog on first use.
codesign_app() {
	log "Codesigning ErgoptiPlus.app (ad-hoc, identifier: $BUNDLE_ID)"
	local entitlements="$LAUNCHER_DIR/ErgoptiPlus.entitlements"
	[ -f "$entitlements" ] || fail "Entitlements file missing: $entitlements"

	# Sign nested bundles first so the host-level pass finds them already valid.
	codesign --force --deep --sign - "$APP_PATH/Contents/Frameworks/Hammerspoon.app"
	codesign --force --deep --sign - "$APP_PATH/Contents/Frameworks/Sparkle.framework"
	local ke_app="$APP_PATH/Contents/Resources/Tools/Karabiner/Karabiner-Elements.app"
	[ -d "$ke_app" ] && codesign --force --deep --sign - "$ke_app" || true

	# Sign the launcher binary with a stable identifier and entitlements.
	codesign --force \
		--sign - \
		--identifier "$BUNDLE_ID" \
		--entitlements "$entitlements" \
		"$APP_PATH/Contents/MacOS/ErgoptiPlus"

	# Sign the outer bundle. --identifier here pins the bundle's own identity.
	codesign --force \
		--sign - \
		--identifier "$BUNDLE_ID" \
		"$APP_PATH"
}

# Zip the bundle as a release artefact. Sparkle expects a zip whose top-level
# entry is the .app itself (no extra wrapping directory).
zip_app() {
	log "Zipping $APP_PATH → $ZIP_PATH"
	(cd "$BUILD_DIR" && zip -qry "$(basename "$ZIP_PATH")" "$(basename "$APP_PATH")")
	[ -f "$ZIP_PATH" ] || fail "Zip did not produce expected output."
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
	launcher_bin="${launcher_bin%%$'\n'*}"
	log "launcher_bin resolved: '$launcher_bin'"
	[ -f "$launcher_bin" ] || fail "launcher_bin does not exist: $launcher_bin"
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
	log "  bundle      : $APP_PATH"
	log "  zip         : $ZIP_PATH"
	log "  version    : $ERGOPTI_VERSION ($ERGOPTI_BUILD)"
	log "  channel    : $ERGOPTI_CHANNEL"
	log "  hammerspoon: $HAMMERSPOON_VERSION"
	log "  karabiner  : $KARABINER_VERSION"
	log "  ollama     : $OLLAMA_VERSION"
}

main "$@"
