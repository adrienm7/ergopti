#!/usr/bin/env bash
# static/ergopti_plus/linux/install/launch.sh
#
# Graphical package entry point. Authenticate missing input permissions before
# the daemon grabs a keyboard, so the user can type into the system prompt.

set -euo pipefail
DRIVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GROUPS_REFRESHED=false
if [ "${1:-}" = --groups-refreshed ]; then GROUPS_REFRESHED=true; shift; fi
SESSION_START=false
SERVICE_MODE=false
if [ "${1:-}" = --service ]; then SERVICE_MODE=true; shift; fi
if [ "${1:-}" = --session-start ]; then
	SESSION_START=true
	shift
	set -- --tray "$@"
fi
for arg in "$@"; do if [ "$arg" = --tray ]; then SESSION_START=true; fi; done

if "$SESSION_START" && ! "$SERVICE_MODE" && command -v systemctl >/dev/null 2>&1 \
	&& systemctl --user show-environment >/dev/null 2>&1; then
	# The packaged unit remains the sole startup owner when systemd is present.
	# XDG only starts the daemon directly on non-systemd desktops.
	systemctl --user daemon-reload
	systemctl --user start ergopti-hotstrings.service
	exit 0
fi

for arg in "$@"; do
	if [ "$arg" = --tray ]; then
		uid="$(id -u)"
		groups=" $(id -nG "$uid") "
		if [[ "$groups" != *' input '* || "$groups" != *' uinput '* ]]; then
			if ! pkexec /bin/bash "$DRIVER_ROOT/install/setup_permissions.sh" --user "$uid"; then
				echo 'Input permission authorization was cancelled or failed.' >&2
				exit 78
			fi
		fi
		groups=" $(id -nG) "
		if [[ "$groups" != *' input '* || "$groups" != *' uinput '* ]]; then
			if "$GROUPS_REFRESHED"; then
				echo 'The session could not acquire its configured input groups.' >&2
				exit 78
			fi
			# sg acquires only its named group. Nest both missing groups, then
			# verify the resulting credentials before taking the instance lock.
			# POSIX quoting is required: sg uses the account's command shell.
			quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
			command="exec /bin/bash $(quote "$DRIVER_ROOT/install/launch.sh") --groups-refreshed"
			if "$SERVICE_MODE"; then command+=' --service'; fi
			for value in "$@"; do command+=" $(quote "$value")"; done
			for group in input uinput; do
				if [[ "$groups" != *" $group "* ]]; then
					command="exec sg $group -c $(quote "$command")"
				fi
			done
			exec /bin/bash -c "$command"
		fi
		break
	fi
done

if "$SESSION_START"; then
	lock_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/ergopti"
	install -d -m 700 "$lock_root"
	exec 9>"$lock_root/ergopti.lock"
	# Keep the lock descriptor across exec; it belongs to this exact daemon.
	if flock --nonblock --conflict-exit-code 75 9; then
		:
	else
		status=$?
		if [ "$status" -eq 75 ]; then exit 0; fi
		exit "$status"
	fi
fi

exec luajit "$DRIVER_ROOT/ergopti_hotstrings.lua" "$@"
