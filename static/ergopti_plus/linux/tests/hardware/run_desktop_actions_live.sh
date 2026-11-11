#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_desktop_actions_live.sh
#
# A desktop for run_desktop_actions_live.lua: an X server with a window manager
# (the confirmation question is a window), a private session bus with GVfs (the
# trash), GSettings on its keyfile backend, and a throwaway HOME.
#
# Needs Xvfb, openbox, dbus-run-session, gio with GVfs, gsettings with the
# GNOME desktop schemas, xdotool, xrandr, luajit with luv and lgi (the dialog
# host).
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
# The inner session re-runs this script after the cd below: name it absolutely,
# since the caller may have given a path relative to another directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || exit 2
cd "$(dirname "$0")/../.." || exit 2
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need Xvfb
need openbox
need dbus-run-session
need gio
need gsettings
need xdotool
# center_mouse reads the monitors through RandR (modules/gestures/pointer_warp.lua).
need xrandr
need luajit
export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
# lua-lgi installs for the distro's Lua, not for LuaJIT.
export LUA_PATH="${LUA_PATH};/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"
export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
luajit -e 'require("lgi")' >/dev/null 2>&1 || { echo "ENVIRONMENT: lgi is unreachable from LuaJIT (lua-lgi)" >&2; exit 2; }
if [ "${1:-}" != "--inside" ]; then
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	DISPLAY_NUMBER=":$((80 + RANDOM % 9))"
	Xvfb "${DISPLAY_NUMBER}" -nolisten tcp >/dev/null 2>&1 &
	XVFB=$!
	for _ in $(seq 40); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" ] && break; sleep 0.25; done
	mkdir -p "${WORK}/run" && chmod 700 "${WORK}/run"
	DISPLAY="${DISPLAY_NUMBER}" HOME="${WORK}" XDG_DATA_HOME="${WORK}/.local/share" \
		XDG_CONFIG_HOME="${WORK}/.config" XDG_RUNTIME_DIR="${WORK}/run" GSETTINGS_BACKEND=keyfile \
		dbus-run-session -- bash "$SELF" --inside
	STATUS=$?
	kill "${XVFB}" 2>/dev/null
	exit "${STATUS}"
fi
openbox >/dev/null 2>&1 &
luajit tests/hardware/run_desktop_actions_live.lua
