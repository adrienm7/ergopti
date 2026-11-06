#!/usr/bin/env bash
# static/ergopti_plus/linux/install/desktop_entry.sh
#
# Desktop Exec uses desktop-entry escaping, not shell quoting. Keep startup and
# uninstall ownership checks on the same byte representation.

ergopti_desktop_exec() {
	local escaped="$1"
	case "$escaped" in
		*$'\n'*|*$'\r'*|*$'\t'*) echo 'Unsupported desktop executable path.' >&2; return 64 ;;
	esac
	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//\$/\\\$}"
	escaped="${escaped//\`/\\\`}"
	escaped="${escaped//%/%%}"
	# String-value decoding precedes Exec argument decoding.
	escaped="${escaped//\\/\\\\}"
	# Desktop implementations inspect the executable before expanding % escapes.
	# Our installed wrappers are Bash scripts; keep their path in an argument.
	printf 'Exec=/bin/bash "%s" --session-start --tray\n' "$escaped"
}

# systemd performs its own quoting, environment and specifier expansion.
# This is intentionally separate from the two Desktop Entry decoding layers.
ergopti_systemd_exec() {
	local escaped="$1"
	case "$escaped" in
		*$'\n'*|*$'\r'*|*$'\t'*) echo 'Unsupported service executable path.' >&2; return 64 ;;
	esac
	escaped="${escaped//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//\$/\$\$}"
	escaped="${escaped//%/%%}"
	printf 'ExecStart=/bin/bash "%s" --tray\n' "$escaped"
}

# Bash read discards NUL bytes, so a binary entry cannot be safely rewritten.
ergopti_desktop_entry_textual() {
	local file="$1" original filtered
	original="$(sha256sum < "$file")" || return 1
	filtered="$(LC_ALL=C tr -d '\000' < "$file" | sha256sum)" || return 1
	[ "${original%% *}" = "${filtered%% *}" ]
}

# Ownership is determined by the command in [Desktop Entry], not by an Exec
# belonging to a desktop action. Duplicate main groups or commands are ambiguous.
ergopti_desktop_entry_owned() {
	local file="$1" launcher="$2" expected line trimmed value group= main_groups=0 commands=0
	ergopti_desktop_entry_textual "$file" || return 1
	expected="$(ergopti_desktop_exec "$launcher")" || return 1
	while :; do
		line=
		if IFS= read -r line; then line="${line%$'\r'}"; else [ -n "$line" ] || break; fi
		# GLib ignores leading whitespace, whitespace around keys, and trailing
		# whitespace around group headers. Preserve value bytes for comparison.
		trimmed="${line#"${line%%[![:space:]]*}"}"
		case "$trimmed" in
			\[*\]*)
				trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
				if [ "$trimmed" = '[Desktop Entry]' ]; then
					group=main; main_groups=$((main_groups + 1))
				else group=other; fi ;;
			*)
				if [ "$group" = main ] && [[ "$trimmed" =~ ^Exec[[:space:]]*= ]]; then
					commands=$((commands + 1))
					value="${trimmed#*=}"
					value="${value#"${value%%[![:space:]]*}"}"
					value="${value%"${value##*[![:space:]]}"}"
					case "Exec=$value" in
						"$expected"|"Exec=$launcher --tray"|"Exec=$launcher --session-start --tray") ;;
						*) return 1 ;;
					esac
				fi ;;
		esac
	done < "$file"
	[ "$main_groups" -eq 1 ] && [ "$commands" -eq 1 ]
}

# Match GLib's effective values in the primary group; later duplicate keys win.
ergopti_desktop_entry_state() {
	local file="$1" wanted="$2" line trimmed key value group= hidden= gnome= managed=
	while :; do
		line=
		if IFS= read -r line; then line="${line%$'\r'}"; else [ -n "$line" ] || break; fi
		trimmed="${line#"${line%%[![:space:]]*}"}"
		case "$trimmed" in
			\[*\]*)
				trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
				if [ "$trimmed" = '[Desktop Entry]' ]; then group=main; else group=other; fi ;;
			*)
				[ "$group" = main ] || continue
				[[ "$trimmed" =~ ^(Hidden|X-GNOME-Autostart-enabled|X-Ergopti-Startup)[[:space:]]*= ]] || continue
				key="${trimmed%%=*}"
				key="${key%"${key##*[![:space:]]}"}"
				value="${trimmed#*=}"
				value="${value#"${value%%[![:space:]]*}"}"
				value="${value%"${value##*[![:space:]]}"}"
				case "$key" in
					Hidden) hidden="$value" ;;
					X-GNOME-Autostart-enabled) gnome="$value" ;;
					X-Ergopti-Startup) managed="$value" ;;
				esac ;;
		esac
	done < "$file"
	case "$wanted" in
		disabled) [[ "$hidden" = true || "$hidden" = 1 || "$gnome" = false || "$gnome" = 0 ]] ;;
		managed) [[ "$managed" = true || "$managed" = 1 ]] ;;
		*) return 1 ;;
	esac
}
ergopti_desktop_entry_disabled() { ergopti_desktop_entry_state "$1" disabled; }
ergopti_desktop_entry_managed() { ergopti_desktop_entry_state "$1" managed; }
