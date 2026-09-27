#!/usr/bin/env bash
# static/ergopti_plus/linux/install/stop_sessions.sh
#
# Package removal stops only the package-owned user unit through its real bus.
# A user override pointing at another installation remains that user's state.

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Package session cleanup requires root.' >&2; exit 77; }
for runtime in /run/user/[0-9]*; do
	[ -S "$runtime/bus" ] || continue
	uid="${runtime##*/}"
	[[ "$uid" =~ ^[0-9]+$ ]] || exit 1
	account="$(getent passwd "$uid")"
	user="${account%%:*}"
	[ -n "$user" ] || exit 1
	command=(runuser -u "$user" -- env "XDG_RUNTIME_DIR=$runtime" "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus" systemctl --user)
	if ! fragment="$("${command[@]}" show ergopti-hotstrings.service -p FragmentPath --value)"; then
		if [ -S "$runtime/bus" ]; then exit 1; fi
		continue
	fi
	case "$fragment" in
		/usr/lib/systemd/user/ergopti-hotstrings.service|/lib/systemd/user/ergopti-hotstrings.service)
			"${command[@]}" disable --now ergopti-hotstrings.service ;;
	esac
done
