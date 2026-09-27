#!/usr/bin/env bash
# static/ergopti_plus/linux/uninstall.sh
#
# Removes an explicitly confirmed standalone installation. Native packages are
# removed by their package manager so its ownership database stays consistent.
# Personal configuration, credentials, metrics and dependencies are retained.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/install/desktop_entry.sh"
PREFIX="${HOME}/.local"
CONFIRMED=false
CHECK_ONLY=false
WAIT_OWNER=
GUI_TITLE=
GUI_ERROR=

while [ "$#" -gt 0 ]; do
	case "$1" in
		--yes) CONFIRMED=true; shift ;;
		--check) CHECK_ONLY=true; shift ;;
		--wait-owner)
			[ "$#" -ge 2 ] || exit 64
			WAIT_OWNER="$2"; shift 2 ;;
		--gui)
			[ "$#" -ge 3 ] || exit 64
			GUI_TITLE="$2"; GUI_ERROR="$3"; shift 3 ;;
		--prefix)
			[ "$#" -ge 2 ] || { echo 'Missing --prefix value.' >&2; exit 64; }
			PREFIX="$2"; shift 2 ;;
		*) echo "Unsupported uninstall argument: $1" >&2; exit 64 ;;
	esac
done

report_exit() {
	local status=$?
	if [ "$status" -ne 0 ] && [ -n "$GUI_TITLE" ]; then
		if ! zenity --error --no-markup --title="$GUI_TITLE" --text="$GUI_ERROR"; then
			echo 'The uninstall failure dialog could not be displayed.' >&2
		fi
	fi
}
trap report_exit EXIT

if ! "$CONFIRMED" && ! "$CHECK_ONLY"; then
	echo 'Explicit --yes confirmation is required; personal data will be retained.' >&2
	exit 64
fi

# A menu worker runs outside the daemon's systemd control group. It may only
# remove files after the exact requesting process has finished its cleanup.
if [ -n "$WAIT_OWNER" ]; then
	[[ "$WAIT_OWNER" =~ ^([0-9]+):([0-9]+)$ ]] || exit 64
	owner_pid="${BASH_REMATCH[1]}"
	owner_start="${BASH_REMATCH[2]}"
	for ((attempt = 0; attempt < 300; attempt++)); do
		if [ ! -e "/proc/$owner_pid/stat" ]; then break; fi
		if ! stat="$(cat "/proc/$owner_pid/stat")"; then continue; fi
		read -ra fields <<< "${stat##*) }"
		if [ "${fields[19]:-}" != "$owner_start" ]; then break; fi
		sleep 0.1
	done
	[ "$attempt" -lt 300 ] || { echo 'The application did not finish shutting down.' >&2; exit 1; }
fi

remove_native_startup() {
	local entry="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/ergopti.desktop"
	if [ -f "$entry" ] && [ ! -L "$entry" ] \
		&& grep -Fxq "$(ergopti_desktop_exec /usr/bin/ergopti)" "$entry"; then
		rm -- "$entry"
	fi
}

if [ "$SCRIPT_DIR" = /usr/lib/ergopti ]; then
	# Never remove package files ourselves, even if authorization is refused.
	if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$SCRIPT_DIR/uninstall.sh" | grep -qx 'ergopti: /usr/lib/ergopti/uninstall.sh'; then
		if "$CHECK_ONLY"; then exit 0; fi
		pkexec /usr/bin/apt-get remove -y ergopti
		remove_native_startup
		exit 0
	elif command -v rpm >/dev/null 2>&1 && [ "$(rpm -qf --qf '%{NAME}' "$SCRIPT_DIR/uninstall.sh")" = ergopti ]; then
		if "$CHECK_ONLY"; then exit 0; fi
		pkexec /usr/bin/rpm -e ergopti
		remove_native_startup
		exit 0
	fi
	echo 'The system installation has no verified package owner.' >&2
	exit 1
fi

# Resolve before deleting and reject system roots and link aliases. The only
# removable standalone tree is the layout created by install.sh.
[ -d "$PREFIX" ] || { echo 'Installation prefix does not exist.' >&2; exit 1; }
PREFIX="$(cd -- "$PREFIX" && pwd -P)"
case "$PREFIX" in
	/|/usr|/usr/local|/app|/nix|/nix/*) echo 'Refusing a system installation prefix.' >&2; exit 1 ;;
esac
LIBRARY="$PREFIX/lib/ergopti"
WRAPPER="$PREFIX/bin/ergopti-hotstrings"
if [ -L "$LIBRARY" ] || [ -L "$WRAPPER" ] || [ ! -f "$LIBRARY/linux/ergopti_hotstrings.lua" ] \
	|| [ ! -f "$LIBRARY/_shared/data/locales/en.json" ] || [ ! -f "$WRAPPER" ]; then
	echo 'The prefix is not a complete owned standalone installation.' >&2
	exit 1
fi
[ "$(cd -- "$LIBRARY" && pwd -P)" = "$LIBRARY" ] || { echo 'Installation path crosses a symbolic link.' >&2; exit 1; }
if { grep -Fqx "INSTALL_ROOT=$(printf '%q' "$LIBRARY")" "$WRAPPER" \
	&& grep -Fqx 'exec bash "${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"' "$WRAPPER"; }; then
	:
elif ! { grep -Fqx "DRIVER_ROOT=\"$LIBRARY/linux\"" "$WRAPPER" \
		|| grep -Fqx "DRIVER_ROOT=$(printf '%q' "$LIBRARY/linux")" "$WRAPPER"; } \
	|| ! { grep -Fqx 'exec bash "${DRIVER_ROOT}/install/launch.sh" --service "$@"' "$WRAPPER" \
		|| grep -Fqx 'exec luajit "${DRIVER_ROOT}/ergopti_hotstrings.lua" "$@"' "$WRAPPER"; }; then
	echo 'The launcher belongs to a different installation.' >&2
	exit 1
fi
if find "$LIBRARY" -name .git -print -quit | grep -q .; then
	echo 'Refusing to remove a source checkout.' >&2
	exit 1
fi
ancestor="$LIBRARY"
while [ "$ancestor" != / ]; do
	if [ -e "$ancestor/.git" ]; then
		echo 'Refusing to remove files inside a source checkout.' >&2
		exit 1
	fi
	ancestor="$(dirname -- "$ancestor")"
done
MANIFEST="$LIBRARY/.ergopti-owned-files"
UNIT="$HOME/.config/systemd/user/ergopti-hotstrings.service"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/ergopti-hotstrings.desktop"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || { echo 'Installation ownership manifest is missing.' >&2; exit 1; }
OWNED=()
REMOVE_UNIT=false
declare -A SEEN=()
while IFS=$'\t' read -r digest relative; do
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid ownership digest.' >&2; exit 1; }
	case "$relative" in
		linux/*|_shared/*|bin/ergopti-hotstrings) owned="$LIBRARY/$relative" ;;
		@wrapper) owned="$WRAPPER" ;;
		@unit) owned="$UNIT" ;;
		@autostart) owned="$AUTOSTART" ;;
		*) echo 'Invalid ownership path.' >&2; exit 1 ;;
	esac
	case "/$relative/" in
		*/../*|*/./*|*//*|*\\*) echo 'Unsafe ownership path.' >&2; exit 1 ;;
	esac
	[ -z "${SEEN[$owned]:-}" ] || { echo 'Duplicate ownership path.' >&2; exit 1; }
	SEEN[$owned]=1
	if [ -e "$owned" ] || [ -L "$owned" ]; then
		[ ! -L "$owned" ] && [ -f "$owned" ] \
			&& [ "$(cd -- "$(dirname -- "$owned")" && pwd -P)" = "$(dirname -- "$owned")" ] \
			|| { echo 'Owned file was replaced by a link or another file type.' >&2; exit 1; }
		actual="$(sha256sum -- "$owned")"
		# A modified shipped file might contain personal data. Keep it, just as
		# we keep files absent from the installer's payload manifest.
		if [ "${actual%% *}" = "$digest" ]; then
			OWNED+=("$owned")
			if [ "$owned" = "$UNIT" ]; then REMOVE_UNIT=true; fi
		fi
	fi
done < "$MANIFEST"

for entry in "$UNIT" "$AUTOSTART"; do
	if [ -e "$entry" ] && ! grep -Fq "$WRAPPER --tray" "$entry" \
		&& ! grep -Fxq "$(ergopti_desktop_exec "$WRAPPER")" "$entry" \
		&& ! grep -Fxq "$(ergopti_systemd_exec "$WRAPPER")" "$entry"; then
		echo "Startup entry belongs to a different installation: $entry" >&2
		exit 1
	fi
done
if [ -f "$UNIT" ] && ! "$REMOVE_UNIT"; then
	echo 'The service was modified or has no ownership record; uninstall was refused.' >&2
	exit 1
fi
if "$CHECK_ONLY"; then exit 0; fi
if [ -f "$UNIT" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	systemctl --user disable --now ergopti-hotstrings.service
fi
for owned in "${OWNED[@]}"; do rm -- "$owned"; done
rm -- "$MANIFEST"
find "$LIBRARY" -depth -type d -empty -delete
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	systemctl --user daemon-reload
fi
