#!/usr/bin/env bash
# static/ergopti_plus/linux/install/compositor_focus.sh
#
# ==============================================================================
# MODULE: Desktop Focus Integration Installer
# DESCRIPTION:
# Installs, enables and removes the two desktop-side halves of the Wayland
# focused-application identity (linux/desktop_focus/): the Ergopti GNOME Shell
# extension and the Ergopti KWin script. GNOME admits its Introspect interface
# to allow-listed senders only and KWin answers only a loaded script, so code
# inside the desktop is the only way to learn which window has focus there.
#
# FEATURES & RATIONALE:
# 1. Per user, in the XDG data folder, for every install kind: install.sh runs
#    it once with messages, install/launch.sh before every daemon start so a
#    .deb, .rpm or AppImage user gets it too, and uninstall.sh removes it.
# 2. Enabled once. A first install enables the integration; an update only
#    refreshes the files, so a user who switched it off keeps it off.
# 3. GNOME Shell under Wayland never loads an extension installed during the
#    session: the enabled list it reads at the next login is written instead,
#    merged into the user's list rather than replacing it.
# 4. Never fatal: a desktop without its tools keeps working, with per-app
#    rules inactive, said in one line. Flatpak's private data folder is not the
#    desktop's, so a sandboxed run installs nothing.
#
# USAGE:
#   compositor_focus.sh install <driver-root>   # the running desktop only
#   compositor_focus.sh remove                  # both, whichever exist
# ==============================================================================

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"

# Pinned by tests/unit/adapters/compositor_focus/test_compositor_focus_assets.lua
# against desktop_focus/gnome/metadata.json and desktop_focus/kwin/metadata.json.
GNOME_FOCUS_UUID="focus@ergopti.fr"
KWIN_FOCUS_ID="ergopti-focus"

DATA_HOME="${XDG_DATA_HOME:-${HOME:+$HOME/.local/share}}"
GNOME_TARGET="${DATA_HOME}/gnome-shell/extensions/${GNOME_FOCUS_UUID}"
KWIN_TARGET="${DATA_HOME}/kwin/scripts/${KWIN_FOCUS_ID}"




# ===================================
# ===================================
# ======= 1/ Helpers ================
# ===================================
# ===================================

# True when XDG_CURRENT_DESKTOP names the given desktop as a whole token.
_desktop_is() {
	local token
	local IFS=:
	for token in ${XDG_CURRENT_DESKTOP:-}; do
		[ "${token,,}" = "$1" ] && return 0
	done
	return 1
}

# Copies a source tree into a target, file by file, refusing a linked target.
_publish_tree() {
	local source="$1" target="$2" file relative
	[ -L "$target" ] && return 1
	install -d -- "$target" || return 1
	while IFS= read -r -d '' file; do
		relative="${file#"$source"/}"
		install -D -m 644 -- "$file" "$target/$relative" || return 1
	done < <(find "$source" -type f -print0)
}

# Whether every file of a source tree is in the target with the same bytes,
# which is what _publish_tree writes. Compared with sha256sum (coreutils):
# diff is absent from minimal Arch, Fedora and openSUSE images.
_same_tree() {
	local source="$1" target="$2" file relative
	[ -d "$target" ] && [ ! -L "$target" ] || return 1
	while IFS= read -r -d '' file; do
		relative="${file#"$source"/}"
		[ -f "$target/$relative" ] || return 1
		[ "$(sha256sum < "$file")" = "$(sha256sum < "$target/$relative")" ] || return 1
	done < <(find "$source" -type f -print0)
}

# Prints the first of the given commands found on PATH.
_first_command() {
	local name
	for name in "$@"; do
		if command -v "$name" >/dev/null 2>&1; then printf '%s\n' "$name"; return 0; fi
	done
	return 1
}

# Asks the running KWin to load or unload a script; harmless without KWin.
_kwin_scripting() {
	command -v gdbus >/dev/null 2>&1 || return 0
	gdbus call --session --dest org.kde.KWin --object-path /Scripting \
		--method "org.kde.kwin.Scripting.$1" "${@:2}" >/dev/null 2>&1 || true
}




# ===================================
# ===================================
# ======= 2/ GNOME Shell ============
# ===================================
# ===================================

_install_gnome() {
	local source="$1/desktop_focus/gnome" first=false enabled label="GNOME Shell"
	[ -d "$GNOME_TARGET" ] || first=true
	# Every daemon start runs this: an unchanged copy says nothing.
	if ! "$first" && _same_tree "$source" "$GNOME_TARGET"; then return 0; fi
	if ! _publish_tree "$source" "$GNOME_TARGET"; then
		ergopti_msg_with "  ⚠  " install.focus_integration_failed "$label" >&2
		return 0
	fi
	if ! "$first"; then
		ergopti_msg_with "  ✔  " install.focus_integration_updated "$label"
		return 0
	fi
	if command -v gnome-extensions >/dev/null 2>&1 \
		&& gnome-extensions enable "$GNOME_FOCUS_UUID" >/dev/null 2>&1; then
		ergopti_msg_with "  ✔  " install.focus_integration_enabled "$label"
		return 0
	fi
	if command -v gsettings >/dev/null 2>&1; then
		enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)"
		case "$enabled" in
			*"'${GNOME_FOCUS_UUID}'"*) ;;
			"@as []"|"[]"|"") enabled="['${GNOME_FOCUS_UUID}']" ;;
			*) enabled="${enabled%]}, '${GNOME_FOCUS_UUID}']" ;;
		esac
		if gsettings set org.gnome.shell enabled-extensions "$enabled" >/dev/null 2>&1; then
			ergopti_msg_with "  ✔  " install.focus_integration_next_login "$label"
			return 0
		fi
	fi
	ergopti_msg_with "  ⚠  " install.focus_integration_failed "$label" >&2
}

_remove_gnome() {
	local enabled kept entry
	[ -d "$GNOME_TARGET" ] && [ ! -L "$GNOME_TARGET" ] || return 0
	# Only the folder this script wrote: a user's own extension of that name stays.
	grep -Fqs "\"uuid\": \"${GNOME_FOCUS_UUID}\"" "$GNOME_TARGET/metadata.json" || return 0
	if command -v gnome-extensions >/dev/null 2>&1; then
		gnome-extensions disable "$GNOME_FOCUS_UUID" >/dev/null 2>&1 || true
	fi
	if command -v gsettings >/dev/null 2>&1; then
		enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)"
		if [[ "$enabled" == *"'${GNOME_FOCUS_UUID}'"* ]]; then
			kept=()
			enabled="${enabled#@as }"
			enabled="${enabled#[}"
			enabled="${enabled%]}"
			IFS=',' read -r -a entries <<< "$enabled"
			for entry in "${entries[@]}"; do
				entry="${entry# }"
				[ "$entry" = "'${GNOME_FOCUS_UUID}'" ] || [ -z "$entry" ] || kept+=("$entry")
			done
			local joined=""
			for entry in "${kept[@]}"; do joined="${joined:+$joined, }$entry"; done
			gsettings set org.gnome.shell enabled-extensions "[${joined}]" >/dev/null 2>&1 || true
		fi
	fi
	rm -r -- "$GNOME_TARGET"
}




# ===================================
# ===================================
# ======= 3/ KWin ===================
# ===================================
# ===================================

_install_kwin() {
	local source="$1/desktop_focus/kwin" first=false writer label="KWin"
	[ -d "$KWIN_TARGET" ] || first=true
	if ! "$first" && _same_tree "$source" "$KWIN_TARGET"; then return 0; fi
	if ! _publish_tree "$source" "$KWIN_TARGET"; then
		ergopti_msg_with "  ⚠  " install.focus_integration_failed "$label" >&2
		return 0
	fi
	if ! "$first"; then
		ergopti_msg_with "  ✔  " install.focus_integration_updated "$label"
		return 0
	fi
	if ! writer="$(_first_command kwriteconfig6 kwriteconfig5)" \
		|| ! "$writer" --file kwinrc --group Plugins --key "${KWIN_FOCUS_ID}Enabled" true >/dev/null 2>&1; then
		ergopti_msg_with "  ⚠  " install.focus_integration_failed "$label" >&2
		return 0
	fi
	# Scripting.start loads every enabled script not yet loaded: this one.
	_kwin_scripting start
	ergopti_msg_with "  ✔  " install.focus_integration_enabled "$label"
}

_remove_kwin() {
	local writer
	[ -d "$KWIN_TARGET" ] && [ ! -L "$KWIN_TARGET" ] || return 0
	grep -Fqs "\"Id\": \"${KWIN_FOCUS_ID}\"" "$KWIN_TARGET/metadata.json" || return 0
	if writer="$(_first_command kwriteconfig6 kwriteconfig5)"; then
		"$writer" --file kwinrc --group Plugins --key "${KWIN_FOCUS_ID}Enabled" --delete >/dev/null 2>&1 || true
	fi
	_kwin_scripting unloadScript "$KWIN_FOCUS_ID"
	rm -r -- "$KWIN_TARGET"
}




# ===================================
# ===================================
# ======= 4/ Entry Point ============
# ===================================
# ===================================

case "${1:-}" in
	install)
		driver_root="${2:-}"
		[ -d "$driver_root/desktop_focus" ] || { printf '[compositor_focus] code=no-source\n' >&2; exit 2; }
		[[ "$DATA_HOME" == /* ]] || exit 0
		[ -e /.flatpak-info ] && exit 0
		if _desktop_is gnome; then _install_gnome "$driver_root"; fi
		if _desktop_is kde; then _install_kwin "$driver_root"; fi
		;;
	remove)
		[[ "$DATA_HOME" == /* ]] || exit 0
		_remove_gnome
		_remove_kwin
		;;
	*)
		# Only install.sh, launch.sh and uninstall.sh call this helper: a wrong verb is
		# their bug, reported as a record, not as a sentence for the user.
		printf '[compositor_focus] code=usage\n' >&2
		exit 2
		;;
esac
exit 0
