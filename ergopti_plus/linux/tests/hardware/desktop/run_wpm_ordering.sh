#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_wpm_ordering.sh
#
# Container proof of TODO « WPM » on Linux: tests/hardware/desktop/wpm_ordering_live.lua
# on an owned Xvfb display with openbox (a real window manager, so a drag
# goes through it), the real metrics collector and its native SQLite owner.
#
# The physical key and pointer events reach the two callbacks the daemon
# calls (the collector's on_keydown, the widget's observe_pointer) in the
# order an evdev reader delivers them; the container has no /dev/input to read
# them from. The drag itself is a real X pointer drag (xdotool).
#
# Needs Xvfb, dbus-launch, openbox, xdotool, luajit, lua-lgi with GTK 3, luv,
# sqlite3. Exit 0 = every check held; 1 = a check failed; 2 = no environment.

set -u
cd "$(dirname "$0")/../../.." || exit 2
command -v xdotool >/dev/null 2>&1 || { echo "ENVIRONMENT: xdotool is missing" >&2; exit 2; }
. tests/hardware/desktop/desktop_session.sh
desktop_session_start "${ERGOPTI_DESKTOP_DISPLAY:-73}"
trap desktop_session_stop EXIT
# The collector's and the widget's own lines stay out of the receipt.
luajit tests/hardware/desktop/wpm_ordering_live.lua > "${DESKTOP_HOME}/wpm.log" 2>&1
STATUS=$?
grep -vE '^[0-9-]+ [0-9:]+ \[[A-Z]+\]' "${DESKTOP_HOME}/wpm.log"
exit "${STATUS}"
