#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_pointer_metrics_live.sh
#
# A desktop for run_pointer_metrics_live.lua: an X server, a session bus, the
# accessibility bus, a window manager and a focused GTK window (the
# application the metrics rows are filed under). Then the real daemon on a
# uinput keyboard and a uinput mouse, and the rows it stores.
#
# Needs root (or the uinput/input groups) for /dev/uinput and the grab, Xvfb,
# dbus-launch, at-spi2-core, openbox, xkbcomp, python3-gi with Gtk 3, xdotool, sqlite3
# and LuaJIT with lua-luv and lua-lgi. Run from anywhere.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../.." || exit 2
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
export LUA_PATH="${LUA_PATH};/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"
export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
BUS_LAUNCHER=""
for candidate in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
	[ -x "${candidate}" ] && BUS_LAUNCHER="${candidate}" && break
done
for tool in Xvfb dbus-launch openbox python3 luajit xkbcomp xdotool sqlite3; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
[ -n "${BUS_LAUNCHER}" ] || { echo "ENVIRONMENT: at-spi-bus-launcher is missing" >&2; exit 2; }

Xvfb :59 -screen 0 1024x768x24 >/dev/null 2>&1 &
PIDS="$!"
export DISPLAY=:59
# An X11 session: the focused application and the cursor position are read from it.
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
cleanup() {
	# shellcheck disable=SC2086
	kill ${PIDS} 2>/dev/null
	return 0
}
# The flow's own status is the script's: an EXIT trap's last command would
# otherwise decide it.
trap 'STATUS=$?; cleanup; exit "${STATUS}"' EXIT
sleep 1
eval "$(dbus-launch --sh-syntax)"
PIDS="${PIDS} ${DBUS_SESSION_BUS_PID}"
"${BUS_LAUNCHER}" --launch-immediately >/dev/null 2>&1 &
PIDS="${PIDS} $!"
# A GTK application joins the accessibility bus once, at start: the window
# below must start after the launcher serves it (run_atspi_focus.sh).
python3 tests/hardware/wait_a11y_bus.py 20 || exit 2
openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
# The rows are filed under the focused application, and nothing is recorded
# while the privacy gate cannot tell the field is not a password.
READY="$(mktemp -u)"
python3 tests/hardware/atspi_fixture_app.py metrics --lifetime-seconds 150 --ready-file "${READY}" >/dev/null 2>&1 &
PIDS="${PIDS} $!"
for _ in $(seq 1 80); do [ -f "${READY}" ] && break; sleep 0.25; done
[ -f "${READY}" ] || { echo "ENVIRONMENT: the focused GTK window never became active" >&2; exit 2; }
rm -f "${READY}"

luajit tests/hardware/run_pointer_metrics_live.lua
