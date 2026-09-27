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
