#!/usr/bin/env bash
# tools/dev/linux-field-shell-checks.sh

# ==============================================================================
# MODULE: Linux field shell checks
# DESCRIPTION:
# The checks tools/dev/collect-linux-field-report.sh runs on the real desktop
# that need no person and no tray click: what the daemon needs from the
# session before it can read or type a key. Each check prints one
# "check=<id> verdict=<pass|fail|skip> codes=<closed codes>" line, the grammar
# of tools/dev/macos-field-shell-checks.sh, then its raw evidence; the
# collector keeps the output as one step file and tools/dev/field-log-analyse.py
# prints the verdict marks and the summary line.
#
# FEATURES & RATIONALE:
# 1. Input access: the daemon writes /dev/uinput and reads the evdev keyboard
#    nodes (install.sh installs the udev rule and the groups that grant both);
#    a node it cannot open is the first cause of "nothing happens".
# 2. Runtime: luajit with luv runs the daemon; without either it never starts.
# 3. The user unit: its name is the one unit file the repository ships, read
#    from the clone, so a renamed unit cannot pass unnoticed.
#
# Sourced only; defines functions and runs nothing. Codes are closed words,
# never a path or a user name.
# ==============================================================================

# Checks that the daemon can write the virtual keyboard and read a key node.
field_input_access() {
	local codes="" verdict=pass nodes=0 readable=0 node
	if [ ! -e /dev/uinput ]; then
		verdict=fail
		codes="uinput_missing"
	elif [ -w /dev/uinput ]; then
		codes="uinput_writable"
	else
		verdict=fail
		codes="uinput_not_writable"
	fi
	for node in /dev/input/event*; do
		[ -e "${node}" ] || continue
		nodes=$((nodes + 1))
		[ -r "${node}" ] && readable=$((readable + 1))
	done
	if [ "${readable}" -gt 0 ]; then
		codes="${codes},evdev_readable"
	else
		verdict=fail
		codes="${codes},evdev_unreadable"
	fi
	printf '  evdev nodes=%s readable=%s groups=%s\n' "${nodes}" "${readable}" "$(id -nG 2>/dev/null)"
	printf 'check=input_access verdict=%s codes=%s\n' "${verdict}" "${codes}"
}

# Checks that luajit runs and loads luv.
field_luajit_runtime() {
	if ! command -v luajit >/dev/null 2>&1; then
		printf 'check=luajit_runtime verdict=fail codes=luajit_missing\n'
		return 0
	fi
	if luajit -e 'require("luv")' >/dev/null 2>&1; then
		printf '  %s\n' "$(luajit -v 2>&1)"
		printf 'check=luajit_runtime verdict=pass codes=luajit_ok,luv_ok\n'
	else
		printf 'check=luajit_runtime verdict=fail codes=luv_missing\n'
	fi
}

# Checks that the shipped user unit is enabled and active.
# $1: clone root.
field_daemon_unit() {
	local unit enabled active verdict=pass
	unit="$(basename "$(ls "$1"/static/ergopti_plus/linux/*.service 2>/dev/null | head -1)")"
	if [ -z "${unit}" ] || [ "${unit}" = "." ]; then
		printf 'check=daemon_unit verdict=fail codes=unit_not_shipped\n'
		return 0
	fi
	if ! command -v systemctl >/dev/null 2>&1; then
		printf 'check=daemon_unit verdict=skip codes=no_systemctl\n'
		return 0
	fi
	enabled="$(systemctl --user is-enabled "${unit}" 2>/dev/null)"
	active="$(systemctl --user is-active "${unit}" 2>/dev/null)"
	printf '  %s enabled=%s active=%s\n' "${unit}" "${enabled:-unknown}" "${active:-unknown}"
	[ "${active}" = active ] || verdict=fail
	printf 'check=daemon_unit verdict=%s codes=enabled_%s,active_%s\n' "${verdict}" \
		"$(printf '%s' "${enabled:-unknown}" | tr -c 'a-z_\n' '_')" "$(printf '%s' "${active:-unknown}" | tr -c 'a-z_\n' '_')"
}

# Runs every check above, in order.
# $1: clone root.
field_linux_checks() {
	field_input_access
	field_luajit_runtime
	field_daemon_unit "$1"
}
