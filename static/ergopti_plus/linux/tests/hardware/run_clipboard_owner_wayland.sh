#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_clipboard_owner_wayland.sh
#
# A Wayland session for `run_clipboard_owner.lua wayland`: sway on its headless
# backend (wlroots, which serves the data-control protocol wl-clipboard needs)
# with a pixman renderer, in a private runtime directory. The harness ends by
# copying with wl-copy, which stays to serve that selection; it and sway are
# stopped here, so nothing outlives the run.
#
# Needs sway, wl-clipboard and luajit with luv. Run from anywhere.
# Exit 0 = every receipt held; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../.." || exit 2
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need sway
need wl-copy
need wl-paste
need luajit
WORK="$(mktemp -d)"
SWAY=""
cleanup() {
	# Only this run's runtime directory: other sessions' wl-copy are left alone.
	for dir in /proc/[0-9]*; do
		[ "${dir#/proc/}" != "$$" ] && grep -qzx "XDG_RUNTIME_DIR=${WORK}/run" "${dir}/environ" 2>/dev/null \
			&& kill "${dir#/proc/}" 2>/dev/null
	done
	[ -n "${SWAY}" ] && kill "${SWAY}" 2>/dev/null
	rm -rf "${WORK}"
}
trap cleanup EXIT
mkdir -p "${WORK}/run" && chmod 700 "${WORK}/run"
printf 'output HEADLESS-1 resolution 1280x800\n' > "${WORK}/sway.conf"
export XDG_RUNTIME_DIR="${WORK}/run" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
sway -c "${WORK}/sway.conf" > "${WORK}/sway.log" 2>&1 &
SWAY=$!
for _ in $(seq 80); do [ -S "${WORK}/run/wayland-1" ] && break; sleep 0.25; done
[ -S "${WORK}/run/wayland-1" ] || { echo "ENVIRONMENT: sway did not open its socket" >&2; tail -5 "${WORK}/sway.log" >&2; exit 2; }
export WAYLAND_DISPLAY=wayland-1
unset DISPLAY
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
luajit tests/hardware/run_clipboard_owner.lua wayland
