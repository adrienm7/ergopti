#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_keep_awake_logind.sh
#
# A real system bus and a real systemd-logind, then run_keep_awake_logind.lua
# twice: under an X11 session (Xvfb :81 with openbox) and under a Wayland one
# (headless sway). logind is the same on both: the inhibitor is a logind object,
# so the two runs prove the daemon reaches it from either session type.
#
# Needs root (it starts the system bus and logind when absent), Xvfb, openbox,
# sway, dbus-daemon, systemd-logind, systemd-inhibit, luajit and lua-luv.
# Exit 0 = both sessions passed; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../../.." || exit 2
export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
LOGIND=/usr/lib/systemd/systemd-logind
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need Xvfb
need openbox
need sway
need dbus-daemon
need systemd-inhibit
need luajit
need busctl
[ -x "${LOGIND}" ] || { echo "ENVIRONMENT: ${LOGIND} is missing" >&2; exit 2; }
PIDS=""
cleanup() { for pid in ${PIDS}; do kill "${pid}" 2>/dev/null; done; }
trap cleanup EXIT

if [ ! -S /run/dbus/system_bus_socket ]; then
	mkdir -p /run/dbus
	dbus-daemon --system --fork || exit 2
fi
if ! busctl --system status org.freedesktop.login1 >/dev/null 2>&1; then
	"${LOGIND}" >/dev/null 2>&1 &
	PIDS="${PIDS} $!"
	sleep 1
fi
busctl --system status org.freedesktop.login1 >/dev/null 2>&1 || { echo "ENVIRONMENT: logind did not start" >&2; exit 2; }
echo "logind: $(busctl --system get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager BlockInhibited)"

RUNTIME="$(mktemp -d)"
chmod 700 "${RUNTIME}"
export XDG_RUNTIME_DIR="${RUNTIME}"
STATUS=0

Xvfb :81 -screen 0 1024x768x24 >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
DISPLAY=:81 openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
env -u WAYLAND_DISPLAY DISPLAY=:81 XDG_SESSION_TYPE=x11 luajit tests/hardware/desktop/run_keep_awake_logind.lua || STATUS=1

WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman sway -c /dev/null >"${RUNTIME}/sway.log" 2>&1 &
PIDS="${PIDS} $!"
for _ in $(seq 50); do ls "${RUNTIME}"/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
SOCKET="$(basename "$(ls "${RUNTIME}"/wayland-? 2>/dev/null | head -n 1)")"
[ -n "${SOCKET}" ] || { echo "ENVIRONMENT: sway did not open a socket" >&2; exit 2; }
env -u DISPLAY WAYLAND_DISPLAY="${SOCKET}" XDG_SESSION_TYPE=wayland luajit tests/hardware/desktop/run_keep_awake_logind.lua || STATUS=1
rm -rf "${RUNTIME}"
exit "${STATUS}"
