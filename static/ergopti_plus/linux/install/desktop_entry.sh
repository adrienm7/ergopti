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

# Ownership is determined by the command in [Desktop Entry], not by an Exec
# belonging to a desktop action. Duplicate main groups or commands are ambiguous.
ergopti_desktop_entry_owned() {
	local file="$1" launcher="$2" expected line group= main_groups=0 commands=0
	expected="$(ergopti_desktop_exec "$launcher")" || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			'[Desktop Entry]') group=main; main_groups=$((main_groups + 1)) ;;
			\[*\]) group=other ;;
			Exec=*)
				[ "$group" = main ] || continue
				commands=$((commands + 1))
				case "$line" in
					"$expected"|"Exec=$launcher --tray"|"Exec=$launcher --session-start --tray") ;;
					*) return 1 ;;
				esac ;;
		esac
	done < "$file"
	[ "$main_groups" -eq 1 ] && [ "$commands" -eq 1 ]
}
