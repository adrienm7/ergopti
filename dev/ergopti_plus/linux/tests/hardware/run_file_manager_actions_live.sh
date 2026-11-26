#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_file_manager_actions_live.sh
#
# A desktop for run_file_manager_actions_live.lua: an X server with a window
# manager (focus moves between real windows), a private session bus, a
# throwaway HOME, a real xterm and a real PCManFM.
#
# Needs Xvfb, openbox, dbus-run-session, xterm, pcmanfm, xdotool, xclip,
# luajit with luv, libX11 and libXtst.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || exit 2
cd "$(dirname "$0")/../.." || exit 2
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need Xvfb
need openbox
need dbus-run-session
need xterm
need pcmanfm
need xdotool
need xclip
need luajit
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
if [ "${1:-}" != "--inside" ]; then
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	DISPLAY_NUMBER=":$((70 + RANDOM % 9))"
	Xvfb "${DISPLAY_NUMBER}" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
	XVFB=$!
	for _ in $(seq 40); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" ] && break; sleep 0.25; done
	mkdir -p "${WORK}/run" && chmod 700 "${WORK}/run"
	DISPLAY="${DISPLAY_NUMBER}" HOME="${WORK}" XDG_DATA_HOME="${WORK}/.local/share" \
		XDG_CONFIG_HOME="${WORK}/.config" XDG_CACHE_HOME="${WORK}/.cache" XDG_RUNTIME_DIR="${WORK}/run" \
		XDG_SESSION_TYPE=x11 dbus-run-session -- bash "$SELF" --inside
	STATUS=$?
	kill "${XVFB}" 2>/dev/null
	exit "${STATUS}"
fi
unset WAYLAND_DISPLAY
openbox >/dev/null 2>&1 &
WM=$!
sleep 0.5
luajit tests/hardware/run_file_manager_actions_live.lua
STATUS=$?
kill "${WM}" 2>/dev/null
exit "${STATUS}"
