#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_keyring_receipts.sh
#
# A real secret service for run_keyring_receipts.lua: a private session bus,
# an X server with a window manager (the unlock prompt is a window), and
# gnome-keyring-daemon with a fresh login keyring in a throwaway HOME.
#
# Needs Xvfb, openbox, dbus-run-session, gnome-keyring, libsecret-tools
# (secret-tool), gdbus, xdotool and luajit with luv. Run from anywhere.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../.." || exit 2
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need Xvfb
need openbox
need dbus-run-session
need gnome-keyring-daemon
need secret-tool
need gdbus
need xdotool
need luajit
if [ "${1:-}" != "--inside" ]; then
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	DISPLAY_NUMBER=":$((90 + RANDOM % 9))"
	Xvfb "${DISPLAY_NUMBER}" -nolisten tcp >/dev/null 2>&1 &
	XVFB=$!
	for _ in $(seq 40); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" ] && break; sleep 0.25; done
	DISPLAY="${DISPLAY_NUMBER}" HOME="${WORK}" dbus-run-session -- bash "$0" --inside
	STATUS=$?
	kill "${XVFB}" 2>/dev/null
	exit "${STATUS}"
fi

export XDG_DATA_HOME="${HOME}/.local/share" XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}"
openbox >/dev/null 2>&1 &
PASSWORD="ergopti-keyring-proof"
# --unlock reads the password up to end of input: no trailing newline.
eval "$(printf '%s' "${PASSWORD}" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
luajit tests/hardware/run_keyring_receipts.lua "${PASSWORD}"
