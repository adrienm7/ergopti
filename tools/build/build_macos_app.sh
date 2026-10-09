#!/usr/bin/env bash
# tools/build_macos_app.sh
#
# ==============================================================================
# MODULE: macOS .app builder
# DESCRIPTION:
# Assembles Ergopti.app — a self-contained macOS bundle that embeds a vendored
# Hammerspoon.app plus the driver payload declared in
# tools/build/macos-bundle-manifest.json, fronted by a Swift launcher
# (compiled from static/ergopti_plus/macos/launcher) that hosts Sparkle and
# spawns the embedded Hammerspoon under a rebranded bundle id.
#
# OUTPUT:
#  build/macos/ErgoptiPlus.app          — signed bundle ready to launch
#  build/macos/ErgoptiPlus.app.zip      — historical ZIP release asset
#  build/macos/ErgoptiPlus.app.tar.xz   — preferred archive consumer prerequisite
#  build/macos/appcast.xml-payload  — the <enclosure> snippet for the appcast,
#                                     emitted once the zip is signed below.
#
# REQUIREMENTS (runtime on the build host):
#  - macOS 13+ (build script runs on macos-latest GitHub runner)
#  - Xcode command-line tools (swift, codesign, iconutil, sips, plutil)
#  - curl, unzip, zip, git, node
#
# RATIONALE:
#  - The script is idempotent: every run wipes build/macos so the output is a
#    deterministic function of inputs. No incremental-build trickery.
#  - All version-stamping (CFBundleVersion, BUNDLE_VERSION, Sparkle key) goes
#    through env vars so the same script drives local dev builds and CI
#    releases without branching.
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"




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

# Sparkle update channel — picks appcast-<channel>.xml on the release host.
# The release workflow sets it to the channel the shared registry
# (_shared/modules/updater/channels.json) gives the release tag; a local build
# defaults to main.
ERGOPTI_CHANNEL="${ERGOPTI_CHANNEL:-main}"

# Karabiner-Elements is not bundled: platform/remap/onboarding.lua downloads the
# DMG pinned in vendor/karabiner-elements/manifest.json, verifies its SHA-256
# and installs it on first use. The 49 MB installer this build used to vendor
# under Resources/Tools/ was never opened by any runtime path.

# Every language the driver ships, as the launcher's CFBundleLocalizations.
# Without them AppKit resolves the bundle to its development region and the
# frameworks it hosts (Sparkle's remaining windows) stay English.
LAUNCHER_LOCALIZATIONS="$(python3 "$REPO_ROOT/tools/build/launcher_localizations.py")"

# Ollama is not bundled either: modules/llm/ollama_binary.lua reuses an
# installed Ollama.app, Homebrew or PATH copy, and the first selection of the
# Ollama backend offers to download the pinned official release into
# Application Support (modules/llm/ensure-ollama-deps.sh). The 79.6 MB binary
# this build used to copy under Resources/Tools/ weighed 29.4 MB of the zip.

# Sparkle EdDSA public key (base64). Empty string means "Sparkle will refuse
# to install updates"; CI must inject the real value from a secret.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

# Stable code-signing identity: a base64 .p12 and its password, both produced
# once by tools/build/create_macos_signing_identity.sh. Set both to sign every
# nested code object with that certificate; set neither to sign ad hoc. An ad
# hoc signature is a new code identity on every build, so macOS forgets the
# Accessibility, Screen Recording, Automation and Login Items grants at each
# update; a stable certificate keeps them.
MACOS_SIGNING_CERTIFICATE_BASE64="${MACOS_SIGNING_CERTIFICATE_BASE64:-}"
MACOS_SIGNING_CERTIFICATE_PASSWORD="${MACOS_SIGNING_CERTIFICATE_PASSWORD:-}"

# GitHub repo coordinates so the appcast URL can be derived. Override via env.
GH_OWNER="${GH_OWNER:-Ergopti}"
GH_REPO="${GH_REPO:-Ergopti}"

# The outer app prohibits duplicate instances. Give the embedded GUI runtime a
# dedicated Ergopti-owned identity while keeping it isolated from stock HS.
BUNDLE_ID="com.ergoptiplus.app"
HAMMERSPOON_BUNDLE_ID="com.ergoptiplus.app.hammerspoon"

BUILD_DIR="$REPO_ROOT/build/macos"
APP_PATH="$BUILD_DIR/ErgoptiPlus.app"
ZIP_PATH="$BUILD_DIR/ErgoptiPlus.app.zip"
LAUNCHER_DIR="$REPO_ROOT/static/ergopti_plus/macos/launcher"

# Architectures of the host executable. They must match the universal slices of
# the embedded Hammerspoon, Sparkle and LuaSocket binaries: a host-only
# `swift build` on the Apple-silicon release runner produced an arm64-only
# launcher that Intel Macs refused to open before any log could be written.
LAUNCHER_ARCHS=(arm64 x86_64)
LAUNCHER_ARCH_FLAGS=()
for arch in "${LAUNCHER_ARCHS[@]}"; do
	LAUNCHER_ARCH_FLAGS+=(--arch "$arch")
done




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

# Strip Sparkle's self-update from a bundle the launcher's updater does not
# drive: the embedded Hammerspoon and the Git-checkout helper. Sparkle reads
# SUAllowsAutomaticUpdates from Info.plist only, while a feed can still come
# back through the bundle's preferences domain, so the switch is pinned here
# too. The feed and the check interval only have to be absent, so a bundle
# that never declared one is already disarmed for that key. Every key is read
# back from a plist that lints, in a format that reads any value type: a
# switch that kept its value, or a feed that survived its removal, fails the
# build instead of shipping a bundle that can update itself.
disarm_bundle_sparkle() {
	local plist="$1"
	local key
	plutil -lint "$plist" >/dev/null || fail "$plist is not a readable property list."
	for key in SUFeedURL SUScheduledCheckInterval; do
		if plutil -extract "$key" xml1 -o - "$plist" >/dev/null 2>&1; then
			plutil -remove "$key" "$plist" || fail "$plist refused the removal of Sparkle's $key."
		fi
	done
	for key in SUEnableAutomaticChecks SUAllowsAutomaticUpdates; do
		plutil -replace "$key" -bool false "$plist"
		[ "$(plutil -extract "$key" raw -o - "$plist")" = "false" ] \
			|| fail "$plist kept Sparkle's $key enabled."
	done
	for key in SUFeedURL SUScheduledCheckInterval; do
		! plutil -extract "$key" xml1 -o - "$plist" >/dev/null 2>&1 \
			|| fail "$plist still declares $key."
	done
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




# =====================================================
# =====================================================
# ======= 4/ Swift launcher compilation ==============
# =====================================================
# =====================================================

# Build the launcher with the official Swift toolchain. We compile in release
# mode for size + speed; the binary then gets relocated into Contents/MacOS.
# Every architecture in LAUNCHER_ARCHS is required and verified: a missing slice
# makes macOS reject the whole app on that CPU before the launcher can log.
build_launcher() {
	if [ "${ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH:-0}" = "1" ]; then
		python3 "$REPO_ROOT/tools/build/automation_query_ci_publisher.py" compile \
			--root "$REPO_ROOT" --directory "$BUILD_DIR/automation-query-ci"
		return
	fi
	log "Building Swift launcher (release, ${LAUNCHER_ARCHS[*]})"
	(
		cd "$LAUNCHER_DIR"
		swift build -c release "${LAUNCHER_ARCH_FLAGS[@]}" --product ErgoptiPlus >&2
	)
	local built_bin
	built_bin="$(swift build -c release "${LAUNCHER_ARCH_FLAGS[@]}" --show-bin-path --package-path "$LAUNCHER_DIR")/ErgoptiPlus"
	[ -f "$built_bin" ] || fail "Swift build did not produce ErgoptiPlus binary."
	local built_archs
	built_archs=" $(lipo -archs "$built_bin") " || fail "lipo could not read launcher architectures."
	local arch
	for arch in "${LAUNCHER_ARCHS[@]}"; do
		[[ "$built_archs" == *" $arch "* ]] \
			|| fail "Launcher binary lacks the $arch slice (has:$built_archs)."
	done
	log "Launcher binary: $built_bin (archs:$built_archs)"
	echo "$built_bin"
}




# ====================================================
# ====================================================
# ======= 5/ App bundle assembly =====================
# ====================================================
# ====================================================

# Assemble the same native executable, guardian registration and linked framework
# for both the complete application and the Git-checkout helper distribution.
assemble_native_runtime() {
	local launcher_bin="$1"
	[ -f "$launcher_bin" ] || fail "Native launcher executable is missing."
	mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Frameworks" \
		"$APP_PATH/Contents/Library/LaunchAgents"
	# Copy the launcher binary into the standard host-executable location.
	cp "$launcher_bin" "$APP_PATH/Contents/MacOS/ErgoptiPlus"
	chmod +x "$APP_PATH/Contents/MacOS/ErgoptiPlus"
	# Keep readonly automation code separate from the outer resource-seal owner.
	cp "$launcher_bin" "$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"
	chmod +x "$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"
	# The read-only helper ships in both full bundles and the source-run runtime.
	local switcher_source="$REPO_ROOT/static/ergopti_plus/macos/native/SystemSwitcherState.swift"
	local switcher_build="$BUILD_DIR/system-switcher-state"
	mkdir -p "$switcher_build"
	local arch
	for arch in arm64 x86_64; do
		xcrun swiftc -O -target "$arch-apple-macosx11.0" "$switcher_source" \
			-o "$switcher_build/$arch"
	done
	lipo -create "$switcher_build/arm64" "$switcher_build/x86_64" \
		-output "$APP_PATH/Contents/MacOS/SystemSwitcherState"
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
	local launcher_build_root="$LAUNCHER_DIR/.build"
	if [ "${ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH:-0}" = "1" ]; then
		launcher_build_root="$BUILD_DIR/automation-query-ci/package/.build"
	fi
	local sparkle_fw
	sparkle_fw="$(find "$launcher_build_root/artifacts" -name "Sparkle.framework" -type d 2>/dev/null | grep -i "macos" | head -1)"
	if [ -z "$sparkle_fw" ]; then
		sparkle_fw="$(find "$launcher_build_root/artifacts" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
	fi
	if [ -z "$sparkle_fw" ]; then
		sparkle_fw="$(find "$launcher_build_root" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
	fi
	[ -n "$sparkle_fw" ] || fail "Sparkle.framework not found under $LAUNCHER_DIR/.build — run 'swift build' in $LAUNCHER_DIR first."
	log "Bundling Sparkle.framework (source: $sparkle_fw)"
	cp -R "$sparkle_fw" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

}

# The "Keyboard layout" menu installs the Ergopti keyboard layout from
# static/ergopti/macos/bundles/, resolved relative to the driver root
# (BUNDLES_RELDIR in ui/menu/menu_keyboard_layout.lua). Ship the newest bundle
# at that same repo-relative path: the menu only ever offers the highest
# version, so older bundles would add weight and nothing else. A build without
# a bundle would ship a menu that can only say "no bundle found", so it fails.
bundle_keyboard_layout() {
	local static_root="$1"
	local src_dir="$REPO_ROOT/static/ergopti/macos/bundles"
	[ -d "$src_dir" ] || fail "Keyboard layout bundles directory missing: $src_dir"
	local latest_version
	latest_version="$(
		find "$src_dir" -mindepth 1 -maxdepth 1 -type d -name 'Ergopti_v*.bundle' \
			| sed -n 's|^.*/Ergopti_v\([0-9][0-9.]*\)\.bundle$|\1|p' \
			| sort -t. -k1,1n -k2,2n -k3,3n \
			| tail -n 1
	)"
	[ -n "$latest_version" ] || fail "No Ergopti_v*.bundle found in $src_dir."
	local latest="Ergopti_v${latest_version}.bundle"
	[ -f "$src_dir/$latest/Contents/Info.plist" ] \
		|| fail "Keyboard layout bundle has no Info.plist: $src_dir/$latest"
	local dest_dir="$static_root/ergopti/macos/bundles"
	log "Bundling keyboard layout $latest"
	mkdir -p "$dest_dir"
	cp -R "$src_dir/$latest" "$dest_dir/"
	[ -f "$dest_dir/$latest/Contents/Info.plist" ] \
		|| fail "Keyboard layout bundle was not packaged at $dest_dir/$latest"
}

# The layout manager installs the Ergopti layouts offline from the keyboard-layout
# registry shipped with the app (modules/keymap/layout_registry.lua), which it
# resolves at the repository path mirrored under Resources: the folder of
# _shared/modules/layouts/defaults.json below the static tree. A build without it
# would need the network to install the very layouts it ships, so it fails.
bundle_layout_registry() {
	local static_root="$1"
	local src_dir="$REPO_ROOT/static/layouts/registry"
	[ -f "$src_dir/index.json" ] || fail "Keyboard-layout registry index missing: $src_dir/index.json"
	local dest_dir="$static_root/layouts/registry"
	log "Bundling the keyboard-layout registry"
	mkdir -p "$static_root/layouts"
	rm -rf "$dest_dir"
	cp -R "$src_dir" "$dest_dir"
	[ -f "$dest_dir/index.json" ] || fail "Keyboard-layout registry was not packaged at $dest_dir"
}

# Assemble the Ergopti.app skeleton, copy the launcher + Hammerspoon and stage
# the driver payload under Resources/static/. The embedded Hammerspoon's
# bundle id is rewritten so its preferences land under our id.
assemble_app() {
	local launcher_bin="$1"
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
	disarm_bundle_sparkle "$hs_plist"

	assemble_native_runtime "$launcher_bin"

	# Mirror the dev tree under Contents/Resources/ at the SAME repo-relative
	# layout (static/ergopti_plus/...) so every Lua path resolves identically in
	# the bundle and in a dev checkout — hs.configdir-relative walks,
	# ``locale.lua``'s gsub("/static/ergopti_plus/macos$"), models_manager_mlx's
	# project_root + "/static/ergopti_plus/macos", etc. — with no code change.
	# The MJConfigDir we point Hammerspoon at is the embedded
	# ``static/ergopti_plus/macos`` subtree.
	local res="$APP_PATH/Contents/Resources"
	local static_root="$res/static"
	mkdir -p "$static_root"

	# The driver, the shared tree and the images the runtime opens, from the one
	# payload manifest (tools/build/macos-bundle-manifest.json): tracked files
	# only, minus the groups no runtime path reads (tests, documentation, debug
	# symbols, developer tooling, the launcher sources, website images).
	# tools/test/test-macos-bundle-payload.cjs proves every runtime reference
	# still resolves in this set.
	node "$REPO_ROOT/tools/build/macos-bundle-payload.cjs" stage "$REPO_ROOT" "$static_root"
	# Generated metadata has actual native archive identities; no catalogue is
	# committed or inferred from a version. A local build may omit this optional
	# runtime, but a supplied producer-input directory must qualify both hosts.
	if [ -n "${ERGOPTI_MANAGED_OLLAMA_INPUTS:-}" ]; then
		python3 "$REPO_ROOT/tools/build/stage-macos-managed-ollama-inputs.py" \
			--repository "$REPO_ROOT" --inputs "$ERGOPTI_MANAGED_OLLAMA_INPUTS" \
			--source "${ERGOPTI_OLLAMA_SOURCE:?native source inputs are required}" \
			--official-archive "${ERGOPTI_OLLAMA_OFFICIAL_ARCHIVE:?official archive is required}" \
			--go "${ERGOPTI_MANAGED_OLLAMA_GO:?absolute pinned Go is required}" \
			--release "${ERGOPTI_RELEASE:-false}" --release-tag "${ERGOPTI_RELEASE_TAG:-}" \
			--release-version "${ERGOPTI_RELEASE_VERSION:-}" --release-channel "$ERGOPTI_CHANNEL" \
			--output "$static_root/ergopti_plus/_shared/modules/llm/managed_ollama_release.json"
	fi
	# The bundle has no .git: the stamp is how the driver's diagnostics name the
	# commit this app was built from. Written before codesign seals the resources.
	bash "$REPO_ROOT/tools/build/write_build_stamp.sh" write "$static_root/ergopti_plus/_shared"

	bundle_keyboard_layout "$static_root"
	bundle_layout_registry "$static_root"
}




# ===========================================
# ===========================================
# ======= 6/ Icon generation ================
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
# ======= 7/ Info.plist generation ====================
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
			<key>CFBundleDevelopmentRegion</key>      <string>en</string>
			<key>CFBundleLocalizations</key>          <array>$LAUNCHER_LOCALIZATIONS</array>
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
			     on the mutable feed branch. SUPublicEDKey must match the
			     private key the CI signing step uses. Sparkle schedules no
			     check and never installs silently: the Lua driver owns the
			     cadence (modules/updater/auto_check.lua), and Sparkle checks,
			     downloads and installs only when the menu asks. -->
			<key>SUFeedURL</key>                      <string>https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/sparkle-appcasts/appcast-$ERGOPTI_CHANNEL.xml</string>
			<key>SUPublicEDKey</key>                  <string>$SPARKLE_PUBLIC_KEY</string>
			<key>SUEnableAutomaticChecks</key>        <false/>
			<key>SUAllowsAutomaticUpdates</key>       <false/>
		</dict>
		</plist>
	PLIST
	plutil -lint "$plist" >/dev/null || fail "Generated Info.plist failed plutil -lint."
}




# ===============================================
# ===============================================
# ======= 8/ Codesign + zip =====================
# ===============================================
# ===============================================

# "-" signs ad hoc. setup_signing_identity() replaces it with the SHA-1 of the
# imported certificate, which codesign reads as an exact identity and not as a
# name that could match another certificate of the search list.
SIGN_IDENTITY="-"
# Temporary keychain holding the imported identity; empty while signing ad hoc.
SIGNING_KEYCHAIN=""
SIGNING_WORK_DIR=""

# Reject half a signing configuration before the long build starts: one
# variable without the other is a secret that failed to reach this run, and
# signing ad hoc there would silently cost every user their permissions.
check_signing_configuration() {
	if [ -n "$MACOS_SIGNING_CERTIFICATE_BASE64" ] && [ -z "$MACOS_SIGNING_CERTIFICATE_PASSWORD" ]; then
		fail "MACOS_SIGNING_CERTIFICATE_BASE64 is set without MACOS_SIGNING_CERTIFICATE_PASSWORD; set both or neither."
	fi
	if [ -z "$MACOS_SIGNING_CERTIFICATE_BASE64" ] && [ -n "$MACOS_SIGNING_CERTIFICATE_PASSWORD" ]; then
		fail "MACOS_SIGNING_CERTIFICATE_PASSWORD is set without MACOS_SIGNING_CERTIFICATE_BASE64; set both or neither."
	fi
}

# Delete the temporary keychain, which also removes it from the search list.
# Runs from the EXIT trap: a keychain that survives would leave the private key
# on the build host, so a failed deletion fails the build.
cleanup_signing_identity() {
	[ -n "$SIGNING_KEYCHAIN" ] || return 0
	local keychain="$SIGNING_KEYCHAIN"
	SIGNING_KEYCHAIN=""
	if ! security delete-keychain "$keychain"; then
		printf '[macos-build] ERROR: could not delete the signing keychain %s\n' "$keychain" >&2
		rm -rf "$SIGNING_WORK_DIR"
		exit 1
	fi
	rm -rf "$SIGNING_WORK_DIR"
	log "Signing keychain deleted"
}

# Say, loudly, what an ad hoc build costs the people who install it.
warn_ad_hoc_signing() {
	log "WARNING: ================================================================"
	log "WARNING: No MACOS_SIGNING_CERTIFICATE_BASE64 / _PASSWORD: signing AD HOC."
	log "WARNING: An ad hoc signature is a new code identity on every build: macOS"
	log "WARNING: will NOT carry the Accessibility, Screen Recording, Automation and"
	log "WARNING: Login Items grants over to this build; users re-grant each one."
	log "WARNING: Create a stable identity once with"
	log "WARNING: tools/build/create_macos_signing_identity.sh and set both variables."
	log "WARNING: ================================================================"
}

# Import the .p12 into a temporary keychain that codesign may use without a
# prompt, and select its one code-signing identity by certificate SHA-1.
setup_signing_identity() {
	[ "$SIGN_IDENTITY" = "-" ] && [ -z "$SIGNING_KEYCHAIN" ] \
		|| fail "The signing identity is already initialized."
	check_signing_configuration
	if [ -z "$MACOS_SIGNING_CERTIFICATE_BASE64" ]; then
		warn_ad_hoc_signing
		return 0
	fi
	require_cmd security
	SIGNING_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-signing.XXXXXX")"
	SIGNING_KEYCHAIN="$SIGNING_WORK_DIR/ergopti-signing.keychain-db"
	trap cleanup_signing_identity EXIT
	log "Signing keychain created: $SIGNING_KEYCHAIN"

	local keychain_password
	keychain_password="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
	[ "${#keychain_password}" -eq 48 ] || fail "Could not generate the signing keychain password."
	local p12="$SIGNING_WORK_DIR/identity.p12"
	(umask 077 && printf '%s' "$MACOS_SIGNING_CERTIFICATE_BASE64" | base64 --decode > "$p12") \
		|| fail "MACOS_SIGNING_CERTIFICATE_BASE64 is not valid base64."
	[ -s "$p12" ] || fail "MACOS_SIGNING_CERTIFICATE_BASE64 decoded to an empty file."

	security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN" \
		|| fail "security create-keychain failed."
	# No automatic lock during the build: a locked keychain fails codesign
	# with errSecInternalComponent halfway through the bundle.
	security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN" \
		|| fail "security set-keychain-settings failed."
	security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN" \
		|| fail "security unlock-keychain failed."
	local search_list=("$SIGNING_KEYCHAIN") existing line
	existing="$(security list-keychains -d user)" || fail "security list-keychains failed."
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line#\"}"
		line="${line%\"}"
		[ -n "$line" ] && search_list+=("$line")
	done <<< "$existing"
	security list-keychains -d user -s "${search_list[@]}" \
		|| fail "security list-keychains could not add the signing keychain."
	security import "$p12" -k "$SIGNING_KEYCHAIN" -f pkcs12 \
		-P "$MACOS_SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null \
		|| fail "security import rejected the certificate: check MACOS_SIGNING_CERTIFICATE_PASSWORD and that the .p12 came from create_macos_signing_identity.sh."
	rm -f "$p12"
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
		-k "$keychain_password" "$SIGNING_KEYCHAIN" >/dev/null \
		|| fail "security set-key-partition-list failed."

	# Without -v: a self-signed certificate is not trusted, and -v lists only
	# trusted identities. codesign signs with it all the same.
	local identities hashes count
	identities="$(security find-identity -p codesigning "$SIGNING_KEYCHAIN")" \
		|| fail "security find-identity failed."
	hashes="$(printf '%s\n' "$identities" \
		| sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]].*$/\1/p' \
		| sort -u)"
	count="$(printf '%s' "$hashes" | grep -c . || true)"
	[ "$count" -eq 1 ] \
		|| fail "Expected exactly one code-signing identity in the imported .p12, found $count."
	SIGN_IDENTITY="$hashes"
	log "Signing with the stable certificate SHA-1 $SIGN_IDENTITY"
}

# Every signature of the bundle goes through here, so no object can be left
# ad hoc once a certificate is imported. A self-signed certificate gets no
# secure timestamp: Apple's timestamp service only serves its own chains.
sign_code() {
	if [ "$SIGN_IDENTITY" = "-" ]; then
		codesign --force --sign - "$@"
	else
		codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp=none "$@"
	fi
}

# Prove the seal, then print the designated requirement: it is what TCC and
# Login Items store, so the CI log shows whether the next build will match it.
verify_app_signature() {
	local bundle="$1"
	codesign --verify --strict --deep --verbose=2 "$bundle" || fail "codesign --verify failed for $bundle"
	local requirement
	requirement="$(codesign -d -r- "$bundle" 2>&1)" || fail "codesign could not read the requirement of $bundle"
	log "Designated requirement of $bundle:"
	while IFS= read -r line; do log "  $line"; done <<< "$requirement"
	if [ "$SIGN_IDENTITY" = "-" ]; then
		log "WARNING: ad hoc requirement (cdhash): the next build will not match it."
		return 0
	fi
	# A self-signed leaf is also its root, so codesign may name either.
	local anchored
	anchored="$(printf '%s\n' "$requirement" | grep -Eic "certificate (leaf|root) = H\"$SIGN_IDENTITY\"" || true)"
	[ "$anchored" -ge 1 ] \
		|| fail "The designated requirement of $bundle does not name the certificate $SIGN_IDENTITY."
}

# Seal the shared runtime without depending on an embedded Hammerspoon bundle.
codesign_native_runtime() {
	if [ "${ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH:-0}" = "1" ]; then
		python3 "$REPO_ROOT/tools/build/automation_query_ci_publisher.py" copied \
			--root "$REPO_ROOT" --directory "$BUILD_DIR/automation-query-ci" --app "$APP_PATH"
	fi
	local entitlements="$LAUNCHER_DIR/ErgoptiPlus.entitlements"
	[ -f "$entitlements" ] || fail "Entitlements file missing: $entitlements"
	sign_code --deep "$APP_PATH/Contents/Frameworks/Sparkle.framework"
	# Sign the launcher binary with a stable identifier and entitlements.
	sign_code \
		--identifier "$BUNDLE_ID" \
		--entitlements "$entitlements" \
		"$APP_PATH/Contents/MacOS/ErgoptiPlus"

	local automation_query="$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"
	[ -f "$automation_query" ] || fail "Native automation query helper is missing."
	sign_code --identifier "$BUNDLE_ID.automation-query" --entitlements "$entitlements" "$automation_query"

	local switcher="$APP_PATH/Contents/MacOS/SystemSwitcherState"
	[ -f "$switcher" ] || fail "Native switcher state helper is missing."
	sign_code --identifier "$BUNDLE_ID.system-switcher-state" "$switcher"
	mkdir -p "$APP_PATH/Contents/Resources"
	shasum -a 256 "$switcher" | awk '{print $1}' \
		> "$APP_PATH/Contents/Resources/system-switcher-state.sha256"

	if [ "${ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH:-0}" = "1" ]; then
		python3 "$REPO_ROOT/tools/build/automation_query_ci_publisher.py" seal \
			--root "$REPO_ROOT" --directory "$BUILD_DIR/automation-query-ci" --app "$APP_PATH"
	fi

	# Sign the outer bundle. --identifier here pins the bundle's own identity.
	sign_code \
		--identifier "$BUNDLE_ID" \
		"$APP_PATH"
	if [ "${ERGOPTI_AUTOMATION_QUERY_CI_PUBLISH:-0}" = "1" ]; then
		python3 "$REPO_ROOT/tools/build/automation_query_ci_publisher.py" verify \
			--root "$REPO_ROOT" --directory "$BUILD_DIR/automation-query-ci" --app "$APP_PATH"
	fi
}

# Sign the app with an explicit --identifier anchored to the bundle ID. The
# identifier alone does not make TCC recognise the next build: an ad hoc
# designated requirement is the code hash (cdhash), which changes on every
# build. Only a stable certificate (setup_signing_identity) turns the
# requirement into identifier + certificate hash, which every later build
# signed with that certificate satisfies.
#
# The entitlements file is included so the launcher binary carries an explicit
# com.apple.security.automation.apple-events claim. Without it some macOS
# versions pop an extra automation-permission dialog on first use.
codesign_app() {
	if [ "$SIGN_IDENTITY" = "-" ]; then
		log "Codesigning ErgoptiPlus.app (ad hoc, identifier: $BUNDLE_ID)"
	else
		log "Codesigning ErgoptiPlus.app (certificate $SIGN_IDENTITY, identifier: $BUNDLE_ID)"
	fi
	# Sign nested code first so the host-level pass finds it already valid.
	# bundle-macos-luasocket.sh builds it into the bundled driver tree.
	local driver_root="$APP_PATH/Contents/Resources/static/ergopti_plus/macos"
	local luasocket="$driver_root/socket/core.so"
	[ -f "$luasocket" ] || fail "Bundled LuaSocket extension missing: $luasocket"
	sign_code "$luasocket"
	sign_code --deep "$APP_PATH/Contents/Frameworks/Hammerspoon.app"

	codesign_native_runtime

}

# Package only the source-native helper here. Its existing ZIP stays separate
# from the full release archive owner; maximum deflate and symbolic links remain
# unchanged for checkout startup and helper installation.
zip_app() {
	log "Zipping $APP_PATH → $ZIP_PATH"
	(cd "$BUILD_DIR" && zip -qry -9 "$(basename "$ZIP_PATH")" "$(basename "$APP_PATH")")
	[ -f "$ZIP_PATH" ] || fail "Zip did not produce expected output."
}




# ==========================================
# ==========================================
# ======= 9/ Entrypoint ===================
# ==========================================
# ==========================================

# Produce the native runtime used by a Git checkout without acquiring any of
# the full application's bundled drivers, language runtimes or model engines.
build_native_helper() {
	for cmd in swift xcrun shasum awk lipo codesign plutil zip find; do require_cmd "$cmd"; done
	check_signing_configuration
	BUILD_DIR="$REPO_ROOT/build/macos-native-helper"
	APP_PATH="$BUILD_DIR/ErgoptiPlus.app"
	ZIP_PATH="$BUILD_DIR/ErgoptiPlus.app.zip"
	[ ! -e "$BUILD_DIR" ] && [ ! -L "$BUILD_DIR" ] \
		|| fail "Native helper output already exists: $BUILD_DIR"
	mkdir -p "$BUILD_DIR"
	local launcher_bin
	launcher_bin="$(build_launcher)"
	assemble_native_runtime "$launcher_bin"
	generate_info_plist
	local plist="$APP_PATH/Contents/Info.plist"
	# The helper is invoked only for headless roles; the Git checkout owns updates.
	for key in CFBundleIconFile CFBundleURLTypes SUPublicEDKey; do
		plutil -remove "$key" "$plist"
	done
	plutil -replace LSUIElement -bool true "$plist"
	disarm_bundle_sparkle "$plist"
	plutil -lint "$plist"
	setup_signing_identity
	codesign_native_runtime
	verify_app_signature "$APP_PATH"
	zip_app
	log "Native helper ready: $ZIP_PATH"
}

main() {
	if [[ $# -eq 1 && "$1" == "--native-helper-only" ]]; then
		build_native_helper
		return
	fi
	[[ $# -eq 0 ]] || fail "Expected no arguments or --native-helper-only."
	for cmd in curl unzip zip ditto tar swift xcrun awk lipo codesign iconutil sips plutil shasum git node; do
		require_cmd "$cmd"
	done
	check_signing_configuration

	clean_build_dir
	download_hammerspoon
	local launcher_bin
	launcher_bin="$(build_launcher)"
	launcher_bin="${launcher_bin%%$'\n'*}"
	log "launcher_bin resolved: '$launcher_bin'"
	[ -f "$launcher_bin" ] || fail "launcher_bin does not exist: $launcher_bin"
	assemble_app "$launcher_bin"
	bash "$REPO_ROOT/tools/build/bundle-macos-luasocket.sh" "$APP_PATH" "$BUILD_DIR/luasocket-build"
	build_icon
	generate_info_plist
	setup_signing_identity
	codesign_app
	verify_app_signature "$APP_PATH"
	verify_app_signature "$APP_PATH/Contents/Frameworks/Hammerspoon.app"
	node "$REPO_ROOT/tools/build/macos-release-archives.cjs" "$APP_PATH" "$BUILD_DIR"

	log "Done."
	log "  bundle      : $APP_PATH"
	log "  archives    : shared release_install.macos_archives"
	log "  version    : $ERGOPTI_VERSION ($ERGOPTI_BUILD)"
	log "  channel    : $ERGOPTI_CHANNEL"
	log "  hammerspoon: $HAMMERSPOON_VERSION"
}

main "$@"
