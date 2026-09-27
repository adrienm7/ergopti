#!/usr/bin/env bash
# static/ergopti_plus/linux/install/setup_permissions.sh
#
# Privileged permission owner shared by packages and the standalone installer.
# Package hooks enroll only users of local graphical sessions, never every
# account in passwd. A graphical launcher may explicitly enroll its own UID.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[ "$(id -u)" = 0 ] || { echo 'Input setup requires administrator privileges.' >&2; exit 77; }
MODE="${1:-}"
case "$MODE" in
	--active-sessions) [ "$#" -eq 1 ] || exit 64 ;;
	--user) [ "$#" -eq 2 ] || exit 64 ;;
	*) echo 'Expected --active-sessions or --user UID.' >&2; exit 64 ;;
esac

resolve_user() {
	local uid="$1" entry name password resolved_uid rest
	[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ] \
		|| { echo 'Refusing a non-desktop account.' >&2; return 1; }
	entry="$(getent passwd "$uid")"
	IFS=: read -r name password resolved_uid rest <<< "$entry"
	[ "$resolved_uid" = "$uid" ] && [ -n "$name" ] || { echo 'Account identity mismatch.' >&2; return 1; }
	printf '%s\n' "$name"
}

enroll_user() {
	local name
	name="$(resolve_user "$1")"
	if command -v usermod >/dev/null 2>&1; then
		usermod -aG input,uinput "$name"
	else
		addgroup "$name" input
		addgroup "$name" uinput
	fi
}

if [ "$MODE" = --user ]; then resolve_user "$2" >/dev/null; fi

for group in input uinput; do
	if ! getent group "$group" >/dev/null; then
		if command -v groupadd >/dev/null 2>&1; then groupadd --system "$group"
		else addgroup -S "$group"; fi
	fi
done
install -d /etc/udev/rules.d /etc/modules-load.d
if [ ! -e /etc/udev/rules.d/99-ergopti-uinput.rules ]; then
	install -m 644 "$SCRIPT_DIR/99-ergopti-uinput.rules" /etc/udev/rules.d/99-ergopti-uinput.rules
fi
if [ ! -e /etc/modules-load.d/ergopti-uinput.conf ]; then
	install -m 644 "$SCRIPT_DIR/ergopti-uinput.conf" /etc/modules-load.d/ergopti-uinput.conf
fi

if [ "$MODE" = --user ]; then
	enroll_user "$2"
elif command -v loginctl >/dev/null 2>&1; then
	# A missing session bus is normal in a package build container. The launcher
	# handles first login; no unrelated account receives keyboard access here.
	if sessions="$(loginctl list-sessions --no-legend 2>/dev/null)"; then
		while read -r session rest; do
			[ -n "$session" ] || continue
			# A user can log out between enumeration and inspection. Read one
			# snapshot; the launcher owns enrollment if this session disappears.
			if ! properties="$(loginctl show-session "$session" -p Type -p Remote -p Class -p Active -p User)"; then
				echo "Session $session could not be inspected; enrollment is deferred to graphical launch." >&2
				continue
			fi
			type= remote= class= active= uid=
			while IFS='=' read -r key value; do
				case "$key" in
					Type) type="$value" ;; Remote) remote="$value" ;;
					Class) class="$value" ;; Active) active="$value" ;; User) uid="$value" ;;
				esac
			done <<< "$properties"
			case "$type:$remote:$class:$active" in
				x11:no:user:yes|wayland:no:user:yes) enroll_user "$uid" ;;
			esac
		done <<< "$sessions"
	else
		echo 'No login manager is running; user enrollment is deferred to graphical launch.' >&2
	fi
fi

if ! modprobe uinput; then
	echo 'The current kernel could not load uinput; its next-boot configuration is installed.' >&2
fi
if [ -S /run/udev/control ]; then
	udevadm control --reload-rules
	udevadm trigger --subsystem-match=misc --sysname-match=uinput
else
	echo 'udev is not running; the installed rule will apply when it starts.' >&2
fi
