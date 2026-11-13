#!/usr/bin/env bash
# tools/build/build-linux-driver.sh
#
# Assembles the Linux driver into a distributable bundle and runs a smoke test.
#
# This script is run by CI (ci-linux.yml job package-linux) after Validate. It:
#   1. Copies the linux driver sources + _shared/ tree into build/linux/
#   2. Copies install.sh
#   3. Copies the versioned standalone launcher
#   4. Builds the native archive backend and the proxy sign-in relay (Go, cgo)
#   5. Verifies all required files exist (integrity check)
#   6. Runs a smoke test: luajit ergopti_hotstrings.lua --help (exit 0 check)
#
# The output at build/linux/ is a self-contained directory that mirrors the
# installed structure under ~/.local/lib/ergopti/.
#
# Usage:
#   bash tools/build/build-linux-driver.sh
#
#   bash tools/build/build-linux-driver.sh --skip-smoke
#     (skip the smoke test — useful when LuaJIT is unavailable)

set -euo pipefail

SKIP_SMOKE=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-smoke) SKIP_SMOKE=true; shift ;;
		*) echo "Unknown option: $1"; exit 1 ;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# NUL framing retains a newline at the end of the checkout directory name.
IFS= read -r -d '' REPO_ROOT < <(CDPATH= cd -Pe -- "${SCRIPT_DIR}/../.." && printf '%s\0' "$PWD")

# ----------------------------------------------------------------------------
# Copy only repository-owned files, with optional root-relative exclusions.
#
# A recursive filesystem copy also picks up ignored runtime state created beside
# the sources. In particular, the metrics WebViews write prefetch.json files
# containing a user's application and typing aggregates. Packaging from Git's
# tracked inventory makes the bundle hermetic and keeps that private state out.
# Usage: copy_tree <src_dir/> <dst_dir/> [--exclude pattern ...]
# ----------------------------------------------------------------------------
copy_tree() {
	local src="$1"; shift
	local dst="$1"; shift
	# The destination stays inside the build directory the caller owns (BUILD_DIR, set below).
	ERGOPTI_COPY_DESTINATION_ROOT="${BUILD_DIR:-}" \
	node "${SCRIPT_DIR}/copy-tracked-tree.cjs" "${REPO_ROOT}" "$src" "$dst" "$@"
}

LINUX_SRC="${REPO_ROOT}/static/ergopti_plus/linux"
SHARED_SRC="${REPO_ROOT}/static/ergopti_plus/_shared"
SHARED_RELATIVE="static/ergopti_plus/_shared"
# A caller that runs several builds at once gives each its own output directory.
BUILD_DIR="${ERGOPTI_LINUX_BUILD_DIR:-${REPO_ROOT}/build/linux}"
case "$BUILD_DIR" in
  /?*) ;;
  *) echo "[ERR] ERGOPTI_LINUX_BUILD_DIR must be an absolute path, got '$BUILD_DIR'" >&2; exit 1 ;;
esac

# The output is removed below. Admit its physical location before creating it,
# including when its last components do not exist yet.
if [ -e "$BUILD_DIR" ] || [ -L "$BUILD_DIR" ]; then
  [ -d "$BUILD_DIR" ] && [ ! -L "$BUILD_DIR" ] || {
    echo "[ERR] Linux build output must be a direct directory: $BUILD_DIR" >&2; exit 1;
  }
  IFS= read -r -d '' RESOLVED_BUILD < <(CDPATH= cd -Pe -- "$BUILD_DIR" && printf '%s\0' "$PWD")
  BUILD_GIT_PROBE="$RESOLVED_BUILD"
else
  BUILD_PARENT="$BUILD_DIR"
  while [ ! -e "$BUILD_PARENT" ] && [ ! -L "$BUILD_PARENT" ]; do
    BUILD_PARENT="${BUILD_PARENT%/*}"
    [ -n "$BUILD_PARENT" ] || BUILD_PARENT=/
  done
  [ -d "$BUILD_PARENT" ] || { echo "[ERR] Linux build output parent is not a directory: $BUILD_PARENT" >&2; exit 1; }
  IFS= read -r -d '' BUILD_GIT_PROBE < <(CDPATH= cd -Pe -- "$BUILD_PARENT" && printf '%s\0' "$PWD")
  if [ "$BUILD_PARENT" = / ]; then BUILD_SUFFIX="/${BUILD_DIR#/}"; else BUILD_SUFFIX="${BUILD_DIR#"$BUILD_PARENT"}"; fi
  case "/$BUILD_SUFFIX/" in
    */../*|*/./*) echo "[ERR] Linux build output has unresolved path components: $BUILD_DIR" >&2; exit 1 ;;
  esac
  RESOLVED_BUILD="${BUILD_GIT_PROBE%/}$BUILD_SUFFIX"
fi

while [[ "$RESOLVED_BUILD" != / && "$RESOLVED_BUILD" == */ ]]; do RESOLVED_BUILD="${RESOLVED_BUILD%/}"; done
[ "$RESOLVED_BUILD" != / ] || { echo "[ERR] Refusing the filesystem root as build output." >&2; exit 1; }
if [ -e "$RESOLVED_BUILD/.git" ] || [ -L "$RESOLVED_BUILD/.git" ]; then
  echo "[ERR] Refusing a Git checkout as build output: $BUILD_DIR" >&2; exit 1
fi
# Check physical ancestors directly: a failed Git query cannot establish that
# an existing directory is outside a sibling checkout.
BUILD_ANCESTOR="$BUILD_GIT_PROBE"
while :; do
  if [ -e "${BUILD_ANCESTOR%/}/.git" ] || [ -L "${BUILD_ANCESTOR%/}/.git" ]; then
    if [ "$BUILD_ANCESTOR" != "$REPO_ROOT" ]; then
      echo "[ERR] Linux build output belongs to another Git checkout: $BUILD_DIR" >&2; exit 1
    fi
    break
  fi
  [ "$BUILD_ANCESTOR" = / ] && break
  BUILD_ANCESTOR="${BUILD_ANCESTOR%/*}"
  [ -n "$BUILD_ANCESTOR" ] || BUILD_ANCESTOR=/
done
# Also retain Git's discovery for nonstandard layouts when it is available;
# refusal of that query never overrides the direct ancestor checks above.
if IFS= read -r -d '' BUILD_GIT_ROOT < <(git -C "$BUILD_GIT_PROBE" rev-parse --show-toplevel 2>/dev/null && printf '\0'); then
  BUILD_GIT_ROOT="${BUILD_GIT_ROOT%$'\n'}"
  if [ "$BUILD_GIT_ROOT" != "$REPO_ROOT" ]; then
    echo "[ERR] Linux build output belongs to another Git checkout: $BUILD_DIR" >&2; exit 1
  fi
fi
case "$REPO_ROOT/" in
  "$RESOLVED_BUILD/"*) echo "[ERR] Linux build output contains the source checkout: $BUILD_DIR" >&2; exit 1 ;;
esac
case "$RESOLVED_BUILD/" in
  "$REPO_ROOT/"*)
    case "$RESOLVED_BUILD/" in
      "$REPO_ROOT/build/"*) [ "$RESOLVED_BUILD" != "$REPO_ROOT/build" ] || { echo "[ERR] Refusing the shared build root." >&2; exit 1; } ;;
      *) echo "[ERR] Linux build output overlaps source files: $BUILD_DIR" >&2; exit 1 ;;
    esac ;;
esac

echo "=== Ergopti Linux driver assembly ==="
echo "  Source  : ${LINUX_SRC}"
echo "  Shared  : ${SHARED_SRC}"
echo "  Build   : ${BUILD_DIR}"
echo ""

# ============================================================================
# 1. Clean and create build directory
# ============================================================================
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/linux"
mkdir -p "${BUILD_DIR}/_shared"

# ============================================================================
# 2. Copy driver sources (exclude vendor)
# ============================================================================
echo "--- Copying Linux driver sources ---"

# `_generated/` ships whole. It used to be excluded and then have ONE file
# copied back by name, which silently dropped the other three the moment they
# were added: the driver hard-errors at startup without features_manifest.lua,
# and loses language names and gestures without locale_table.lua and
# gesture_emit_actions.lua. Every file in there is tracked and read at runtime,
# so an allow-list of one was only ever going to rot.
copy_tree "${LINUX_SRC}/" "${BUILD_DIR}/linux/" --exclude vendor

# Generate the private native backend from the canonical C/header after the
# tracked copy. Ignored local .so files and prior private fixture outputs never
# enter this bundle. The helper refuses an already occupied destination.
bash "${SCRIPT_DIR}/build-linux-native-output.sh" --output-directory "${BUILD_DIR}/linux/bin"

# The local NTLM/Negotiate relay (docs/design/proxy-auth-relay.md) lives beside
# the archive backend, where infra/proxy_auth_relay.lua resolves it. Every
# package made from this bundle carries it; the Flatpak rebuilds it in its SDK.
bash "${SCRIPT_DIR}/build-proxy-relay.sh" --output "${BUILD_DIR}/linux/bin/ergopti-proxy-relay"

# ============================================================================
# 3. Copy the shared runtime tree
# ============================================================================
echo "--- Copying _shared tree ---"

# Every shared WebView application is production runtime data. Copying only the
# four root helpers produced a valid-looking bundle in which all fifteen window
# openers rendered an app-not-found page. Keep the complete offline UI tree;
# Corpus fixtures and website-only source-review declarations are development data.
copy_tree "${SHARED_SRC}/" "${BUILD_DIR}/_shared/" --exclude corpus \
	--exclude settings/data/features/behaviors.json

# Every Linux package (.deb, .rpm, AppImage, Flatpak, tarball) is made from this
# shared tree, and none of them carries a .git: without the stamp the daemon's
# diagnostics cannot name the commit it was built from.
bash "${SCRIPT_DIR}/write_build_stamp.sh" write "${BUILD_DIR}/_shared"

echo "--- Copying the .keylayout converter ---"

# Registry layouts reach Linux as their macOS .keylayout only: the package
# carries no XKB file of any layout, and modules/keymap/layout_registry.lua converts
# the downloaded file on the user's machine in Lua (_shared/layouts/engine/
# xkb_converter.lua), from the keysym table, symbols template and key types that
# ship in data/. The Python converter, the repository-only regeneration script and
# the tests stay behind: the package does not run them.
copy_tree "${REPO_ROOT}/static/ergopti/linux/xkb_generation/" "${BUILD_DIR}/linux/xkb_generation/" \
	--exclude tests --exclude generate_xkb_files.py --exclude keylayout_to_xkb.py

echo "--- Copying the user XKB installer and the layout registry ---"

# The layout manager installs a converted layout in the user XKB tree without
# sudo (user_layout_installer.py and the modules it imports), and installs the
# Ergopti layouts offline from the registry folder shipped at its repository
# path below the driver (modules/keymap/layout_registry.lua).
mkdir -p "${BUILD_DIR}/linux/xkb_installation"
cp "${REPO_ROOT}/static/ergopti/linux/xkb_installation/user_layout_installer.py" "${BUILD_DIR}/linux/xkb_installation/"
cp "${REPO_ROOT}/static/ergopti/linux/xkb_installation/layout_package.py" "${BUILD_DIR}/linux/xkb_installation/"
cp "${REPO_ROOT}/static/ergopti/linux/xkb_installation/desktop_activation.py" "${BUILD_DIR}/linux/xkb_installation/"
copy_tree "${REPO_ROOT}/static/layouts/registry/" "${BUILD_DIR}/linux/static/layouts/registry/"

# ============================================================================
# 4. Copy the install script
# ============================================================================
echo "--- Copying install script ---"

cp "${LINUX_SRC}/install.sh" "${BUILD_DIR}/install.sh"
chmod +x "${BUILD_DIR}/install.sh"

# ============================================================================
# 5. Copy the versioned launcher
# ============================================================================
echo "--- Copying versioned launcher ---"

mkdir -p "${BUILD_DIR}/bin"
install -m 755 "${LINUX_SRC}/install/standalone_launcher.sh" "${BUILD_DIR}/bin/ergopti-hotstrings"

# ============================================================================
# 6. Integrity check — verify all required files exist
# ============================================================================
echo ""
echo "--- Integrity check ---"

REQUIRED_FILES=(
	"linux/bin/libergopti_archive_publication.so"
	"linux/bin/ergopti-proxy-relay"
	"linux/ergopti_hotstrings.lua"
	"linux/apps/encryptor.lua"
	"linux/apps/app_cloner.lua"
	"_shared/apps/data/encryptor/format.json"
	"_shared/apps/data/app_cloner/families.json"
	"linux/modules/hotstrings/engine.lua"
	"linux/modules/hotstrings/loader.lua"
	"linux/modules/hotstrings/injector.lua"
	"linux/modules/hotstrings/input_reader.lua"
	"linux/modules/hotstrings/device_finder.lua"
	"linux/modules/keystats/metrics_collector.lua"
	"linux/core/network/adapters/http_client.lua"
	"linux/adapters/tray_menu.lua"
	"linux/core/i18n/engine/locale.lua"
	"linux/install/config_home.sh"
	"linux/install/ownership_schema.sh"
	# The localized sentences of the shell scripts and their reader.
	"linux/install/messages.sh"
	"linux/_generated/shell_messages/en.msg"
	"linux/modules/updater/ownership_receipt.lua"
	"linux/core/i18n/engine/i18n.lua"
	"linux/core/timing/engine/timings.lua"
	"linux/ui/webkit_host.lua"
	"linux/tests/run.lua"
	"linux/tests/helpers.lua"
	# Every tracked file under _generated/. The daemon refuses to start without
	# the manifest, and degrades without the other three, so their absence must
	# fail the build rather than the user's first launch.
	"linux/_generated/features_manifest.lua"
	"_shared/settings/engine/features/manifest.lua"
	"_shared/settings/engine/features/manifest_data.lua"
	"linux/_generated/gesture_emit_actions.lua"
	"linux/_generated/locale_table.lua"
	"linux/_generated/config_template.toml"
	"_shared/hotstrings/engine/matcher/init.lua"
	"_shared/hotstrings/engine/matcher/cascade.lua"
	"_shared/metrics/engine/utils.lua"
	"_shared/metrics/engine/metrics.lua"
	"_shared/metrics/engine/aggregator/helpers.lua"
	"_shared/ai/engine/prediction/prompt_builder_core.lua"
	"linux/infra/llm_bridge.lua"
	"_shared/tray/protocol.lua"
	# The tray logo. Without it the icon silently falls back to a generic glyph.
	"_shared/tray/data/ergopti_tray.png"
	"_shared/tray/data/ergopti_tray_paused.png"
	"_shared/core/lifecycle/engine/compat/base64.lua"
	"_shared/core/lifecycle/engine/compat/utf8.lua"
	"_shared/layouts/engine/layers/terminators.lua"
	"_shared/layouts/engine/layers/terminators_catalogue.lua"
	# The logs folder and log names: the logger sink cannot start without it.
	"_shared/core/fs/engine/app_dirs.lua"
	# Application and bundle names, service labels and external hosts.
	"_shared/core/text/engine/identifiers.lua"
	# Their shell copy: install.sh and the Ollama installer source it.
	"_shared/core/text/data/identifiers.sh"
	"_shared/platform/input/keycodes/evdev.lua"
	"_shared/updater/engine/version_core.lua"
	"_shared/updater/engine/release_sources.lua"
	"_shared/updater/engine/channels.lua"
	"_shared/updater/engine/schedule.lua"
	# The About submenu's version row: the tray cannot build without it.
	"_shared/updater/engine/version_label.lua"
	# Registry layouts: the client, its settings and keycode table, and the
	# conversion data it reads (tools/test/
	# test-linux-ships-keylayout-converter.cjs keeps this list complete).
	"_shared/layouts/engine/registry/registry_core.lua"
	"_shared/layouts/engine/composer/catalogue.lua"
	"_shared/layouts/engine/composer/keylayout.lua"
	"_shared/layouts/engine/composer/xkb_converter.lua"
	"_shared/layouts/data/defaults.json"
	"_shared/layouts/data/mac_keycodes.json"
	"linux/modules/keymap/layout_registry.lua"
	"linux/core/process/adapters/runner.lua"
	"linux/xkb_generation/data/key_sym.json"
	"linux/xkb_generation/data/xkb_symbols.txt"
	"linux/xkb_generation/data/xkb_types.txt"
	"linux/xkb_installation/user_layout_installer.py"
	"linux/xkb_installation/layout_package.py"
	"linux/xkb_installation/desktop_activation.py"
	"linux/static/layouts/registry/index.json"
	# The shipped Ergopti extension supplies its reduction/roll packs and the
	# exact MagicKey sections declared by its manifest.
	"linux/static/layouts/registry/ergopti/manifest.toml"
	"linux/static/layouts/registry/ergopti/hotstrings/sfbsreduction.toml"
	"linux/static/layouts/registry/ergopti/hotstrings/rolls.toml"
	"linux/static/layouts/registry/ergopti/hotstrings/repeatcorrections.toml"
	"linux/static/layouts/registry/ergopti/hotstrings/suffixes_a.toml"
	"linux/static/layouts/registry/ergopti/hotstrings/magickeyreplace.toml"
	"linux/install/layout_registry.sh"
	"linux/install/native_source_build.sh"
	# The .rpm wrapper and the standalone launcher admit native_modules/ here.
	"linux/install/native_modules_env.sh"
	"_shared/updater/data/defaults.json"
	# The daemon migrates config.toml at start; without the registry or the
	# engine every session would refuse to write it.
	"_shared/settings/data/config_schema/migrations.toml"
	"_shared/settings/engine/migration/migrate.lua"
	"_shared/updater/data/channels.json"
	"_shared/core/text/engine/json.lua"
	"_shared/core/text/engine/unicode_case/init.lua"
	"_shared/core/text/engine/unicode_case/data.lua"
	"_shared/keyboard/engine/wrap_pair.lua"
	# What ends CapsWord on its own; the shortcuts manager loads it.
	"_shared/keyboard/engine/caps_word_auto_off.lua"
	# Where a previous/next desktop step lands; the gesture manager loads it.
	"_shared/keyboard/engine/desktop_navigation.lua"
	"_shared/platform/input/send_input.lua"
	"_shared/shortcuts/engine/brightness_actions.lua"
	"_shared/shortcuts/engine/brightness_actions_data.lua"
	"_shared/core/ui/engine/native_theme_data.lua"
	"_shared/shortcuts/data/actions/brightness.json"
	"_shared/shortcuts/data/actions/send_keys.json"
	"_shared/shortcuts/data/actions/tap_keys.json"
	"_shared/layouts/data/keycodes/evdev.json"
	# Shared layer data used by the configuration editor.
	"_shared/layouts/engine/layers/layers.lua"
	"_shared/layouts/data/layer_actions.toml"
	"_shared/layouts/data/keycodes/physical_keys.json"
	"_shared/core/i18n/data/locales/fr.json"
	"_shared/core/i18n/data/locales/en.json"
	"_shared/core/timing/data/constants.toml"
	"_shared/ai/data/defaults.json"
	"_shared/ai/data/profiles.json"
	"_shared/settings/data/features/manifest.schema.json"
	"_shared/menu/data/menu_manifest.json"
	"_shared/hotstrings/data/catalogue/defaults.toml"
	"_shared/ui/host_bridge.js"
	"_shared/ui/i18n.js"
	"install.sh"
	"bin/ergopti-hotstrings"
)

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
	if [ ! -f "${BUILD_DIR}/${f}" ]; then
		echo "  MISSING: ${f}"
		MISSING=$((MISSING + 1))
	fi
done

# The WebView asset set is owned by the source tree, not a handwritten package
# allow-list. The build directory was recreated above, so byte-for-byte presence
# proves that every current page and every local dependency reaches all package
# formats that consume this bundle.
UI_FILE_COUNT=0
while IFS= read -r -d '' tracked; do
	relative="${tracked#"${SHARED_RELATIVE}/ui/"}"
	UI_FILE_COUNT=$((UI_FILE_COUNT + 1))
	if [ ! -f "${BUILD_DIR}/_shared/ui/${relative}" ]; then
		echo "  MISSING UI ASSET: _shared/ui/${relative}"
		MISSING=$((MISSING + 1))
	elif ! cmp -s "${SHARED_SRC}/ui/${relative}" "${BUILD_DIR}/_shared/ui/${relative}"; then
		echo "  CHANGED UI ASSET: _shared/ui/${relative}"
		MISSING=$((MISSING + 1))
	fi
done < <(git -C "${REPO_ROOT}" ls-files -z -- "${SHARED_RELATIVE}/ui" | sort -z)

if [ $UI_FILE_COUNT -eq 0 ]; then
	echo "  MISSING: no shared UI assets were discovered in the source tree"
	MISSING=$((MISSING + 1))
fi

# The list above names files; the bound hotstring files of the shipped layout
# extensions come from their manifests (the same check as the macOS build), so a
# binding added there is required here without another list to update.
if ! python3 "${SCRIPT_DIR}/check_layout_extension_payload.py" \
	"${REPO_ROOT}/static/layouts/registry" "${BUILD_DIR}/linux/static/layouts/registry"; then
	echo "  MISSING: a bound layout extension hotstring file"
	MISSING=$((MISSING + 1))
fi

if [ $MISSING -gt 0 ]; then
	echo ""
	echo "ERROR: ${MISSING} required file(s) missing from build."
	exit 1
fi

FILE_COUNT=$(find "${BUILD_DIR}" -type f | wc -l)
echo "  OK — all ${#REQUIRED_FILES[@]} required files and ${UI_FILE_COUNT} UI assets present (${FILE_COUNT} total files)."

# ============================================================================
# 7. Smoke test — verify the assembled driver boots without crashing
# ============================================================================
if [ "$SKIP_SMOKE" = true ]; then
	echo ""
	echo "--- Smoke test SKIPPED (--skip-smoke) ---"
	echo ""
	echo "=== Linux driver assembled successfully ==="
	echo "  Output: ${BUILD_DIR}/"
	exit 0
fi

echo ""
echo "--- Smoke test ---"

# Find an available Lua runtime
LUA_BIN=""
for candidate in luajit lua5.4 lua; do
	if command -v "$candidate" >/dev/null 2>&1; then
		LUA_BIN="$candidate"
		break
	fi
done

if [ -z "$LUA_BIN" ]; then
	echo "ERROR: No Lua runtime found for the required smoke test." >&2
	echo "  Install luajit or lua5.4, or explicitly select --skip-smoke." >&2
	exit 1
else
	echo "  Lua runtime: ${LUA_BIN} ($(${LUA_BIN} -v 2>&1 || true))"

	# Set up LUA_PATH so requires resolve from the build directory.
	# On Windows, Lua's package.path expects backslashes — use forward slashes
	# in the template and let Lua handle normalization via the inline -e script
	# (which constructs package.path programmatically, avoiding shell escaping).
	BUILD_DIR_FWD="${BUILD_DIR}"  # already forward-slash from bash on Windows

	# Helper: runs a Lua one-liner with the build directory on package.path.
	# Keep the path outside Lua source: quotes, backslashes and newlines are
	# valid Linux filename bytes, not Lua lexical syntax.
	_lua_with_path() {
		local lua_code="$1" lua_command
		lua_command="$(command -v "$LUA_BIN")" || return 1
		case "$lua_command" in
			/*) ;;
			*/*) lua_command="$PWD/$lua_command" ;;
		esac
		# Lua treats ; and ? as search-path syntax, including in absolute paths.
		# Resolve relative templates after entering the staged build directory.
		(
			cd -- "$BUILD_DIR_FWD" || exit 1
			"$lua_command" -e "
				local sep = package.config:sub(1,1)
				local driver_root = 'linux'
				local shared_lua = '_shared'
				package.path = driver_root .. sep .. '?.lua;' ..
				               driver_root .. sep .. '?' .. sep .. 'init.lua;' ..
				               shared_lua .. sep .. '?.lua;' ..
				               shared_lua .. sep .. '?' .. sep .. 'init.lua;' ..
				               (package.path or '')
				${lua_code}
			"
		) 2>&1
	}

	# Test 1: --help must exit 0
	echo "  Test: --help exits 0..."
	LUA_HELP_COMMAND="$(command -v "$LUA_BIN")"
	case "$LUA_HELP_COMMAND" in /*) ;; */*) LUA_HELP_COMMAND="$PWD/$LUA_HELP_COMMAND" ;; esac
	if (cd -- "${BUILD_DIR}/linux" && "$LUA_HELP_COMMAND" ergopti_hotstrings.lua --help) >/dev/null 2>&1; then
		echo "    OK — --help exits 0"
	else
		echo "    FAIL — --help exited non-zero"
		exit 1
	fi

	# On real Linux (CI), also verify the engine and shared modules load.
	# Skip on Windows/MSYS — Git Bash paths (/d/...) are incompatible with
	# Lua's package.path which expects Windows-style (d:\...).
	if [[ "$(uname -s 2>/dev/null || echo '')" == Linux ]]; then
		# Test 2: require the engine module (validates package.path)
		echo "  Test: require('modules.hotstrings.engine')..."
		if _lua_with_path "
			local engine = require('modules.hotstrings.engine')
			local e = engine.new()
			assert(e ~= nil, 'engine.new() returned nil')
			assert(type(e.on_char) == 'function', 'on_char is not a function')
			assert(type(e.load_mappings) == 'function', 'load_mappings is not a function')
			print('OK')
		"; then
			echo "    OK — engine module loads and instantiates"
		else
			echo "    FAIL — engine module failed to load"
			exit 1
		fi

		# Test 3: verify all shared modules can be required (non-blocking)
		echo "  Test: require all shared modules..."
		SHARED_MODS=(
			"metrics.engine.utils"
			"metrics.engine.metrics"
			"metrics.engine.aggregator.helpers"
			"ai.engine.prediction.prompt_builder_core"
			"infra.llm_bridge"
			"tray.protocol"
			"core.lifecycle.engine.compat.utf8"
			"layouts.engine.layers.terminators"
			"platform.input.keycodes.evdev"
			"updater.engine.version_core"
			"updater.engine.release_sources"
		)
		SHARED_OK=true
		for mod in "${SHARED_MODS[@]}"; do
			if ! _lua_with_path "
				local ok, m = pcall(require, '${mod}')
				assert(ok, 'require failed: ' .. tostring(m))
			"; then
				echo "    FAIL — require('${mod}') failed"
				SHARED_OK=false
			fi
		done
		if [ "$SHARED_OK" != true ]; then
			exit 1
		fi
		echo "    OK — all ${#SHARED_MODS[@]} shared modules load"
	else
		echo "  (skipping engine/module tests — not on Linux, uses native paths)"
	fi
fi

echo ""
echo "=== Linux driver assembled successfully ==="
echo "  Output  : ${BUILD_DIR}/"
echo "  Binary   : ${BUILD_DIR}/bin/ergopti-hotstrings"
echo "  Installer: ${BUILD_DIR}/install.sh"
