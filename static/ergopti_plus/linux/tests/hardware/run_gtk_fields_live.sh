#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_gtk_fields_live.sh
#
# A desktop for the flows that act inside real GTK text fields
# (run_shortcut_transforms_live.lua, run_hotstring_fields_live.lua): an X server,
# openbox (waited for until it announces _NET_ACTIVE_WINDOW, tests/hardware/
# x11_window_manager.py), a private session bus whose accessibility bus the
# privacy owner reads, a throwaway HOME, and the flow, which opens its own
# tests/hardware/gtk_fields_fixture.py window.
#
# Usage: run_gtk_fields_live.sh tests/hardware/<flow>.lua
# Needs Xvfb, openbox, dbus-run-session, xdotool, xclip, python3 with GTK 3,
# luajit with luv, libX11 and libXtst.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || exit 2
cd "$(dirname "$0")/../.." || exit 2
FLOW="${1:-}"
[ -f "${FLOW}" ] || { echo "usage: run_gtk_fields_live.sh tests/hardware/<flow>.lua" >&2; exit 2; }
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
for tool in Xvfb openbox dbus-run-session xdotool xclip python3 luajit; do need "${tool}"; done
python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk" 2>/dev/null \
	|| { echo "ENVIRONMENT: Python GTK 3 bindings are missing" >&2; exit 2; }
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
if [ "${2:-}" != "--inside" ]; then
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	DISPLAY_NUMBER=":$((80 + RANDOM % 9))"
	Xvfb "${DISPLAY_NUMBER}" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
	XVFB=$!
	for _ in $(seq 40); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" ] && break; sleep 0.25; done
	mkdir -p "${WORK}/run" && chmod 700 "${WORK}/run"
	DISPLAY="${DISPLAY_NUMBER}" HOME="${WORK}" XDG_DATA_HOME="${WORK}/.local/share" \
		XDG_CONFIG_HOME="${WORK}/.config" XDG_CACHE_HOME="${WORK}/.cache" XDG_STATE_HOME="${WORK}/.local/state" \
		XDG_RUNTIME_DIR="${WORK}/run" XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 NO_AT_BRIDGE=0 \
		dbus-run-session -- bash "$SELF" "${FLOW}" --inside
	STATUS=$?
	kill "${XVFB}" 2>/dev/null
	exit "${STATUS}"
fi
unset WAYLAND_DISPLAY AT_SPI_BUS_ADDRESS
openbox >/dev/null 2>&1 &
WM=$!
python3 tests/hardware/x11_window_manager.py ready || { kill "${WM}" 2>/dev/null; exit 1; }
luajit "${FLOW}"
STATUS=$?
kill "${WM}" 2>/dev/null
exit "${STATUS}"
