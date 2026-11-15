#!/usr/bin/env bash
# tests/hardware/desktop/run_wayland_sessions.sh
#
# ==============================================================================
# MODULE: Headless Wayland Sessions For The Desktop-Change And Focus Proofs
# DESCRIPTION:
# Starts real compositors headless, each with its own XDG_RUNTIME_DIR and
# session bus, and runs the driver's real modules inside them:
#   - sway (WLR_BACKENDS=headless): workspace changes counted through swaymsg;
#   - KWin 5.27 (kwin_wayland --virtual): desktop changes through KWin's D-Bus;
#   - GNOME Shell 46 (--headless --wayland): no workspace interface and no
#     focused-window query, each with its stated reason;
#   - labwc (headless): two foot windows, focus followed through the
#     wlr-foreign-toplevel listing.
# lswt 2.x is not packaged by Ubuntu 24.04, so `lswt` on the PATH is
# foreign_toplevel_probe.c, built here: the activated state is the
# compositor's own protocol answer, the JSON writer is ours.
#
# Needs: sway, labwc, kwin-wayland, qdbus-qt5, gnome-shell, foot,
# dbus-run-session, libwayland-dev, gcc, luajit with luv. Run from anywhere.
# Exit 0 = every session verified; 1 = a failure; 2 = no environment.
# ==============================================================================

set -u
DRIVER_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)" || exit 2
TESTS="${DRIVER_ROOT}/tests/hardware/desktop"
missing() { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
command -v sway >/dev/null 2>&1 || missing sway
command -v swaymsg >/dev/null 2>&1 || missing swaymsg
command -v labwc >/dev/null 2>&1 || missing labwc
command -v kwin_wayland >/dev/null 2>&1 || missing kwin_wayland
command -v gnome-shell >/dev/null 2>&1 || missing gnome-shell
command -v foot >/dev/null 2>&1 || missing foot
command -v qdbus >/dev/null 2>&1 || missing qdbus
command -v dbus-run-session >/dev/null 2>&1 || missing dbus-run-session
command -v gcc >/dev/null 2>&1 || missing gcc
command -v luajit >/dev/null 2>&1 || missing luajit
luajit -e 'require("luv")' >/dev/null 2>&1 || { echo "ENVIRONMENT: luv is unreachable from LuaJIT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-wayland-sessions-XXXXXX")" || exit 2
# A Unix socket path holds at most 107 bytes; the compositors' sockets live
# two levels below the work directory.
if [ "${#WORK}" -gt 64 ]; then
	echo "ENVIRONMENT: ${WORK} is too long for the compositor sockets; set a shorter TMPDIR" >&2
	rm -rf -- "${WORK}"
	exit 2
fi
PIDS=""
cleanup() {
	for pid in ${PIDS}; do kill "${pid}" 2>/dev/null; done
	wait 2>/dev/null
	rm -rf -- "${WORK}"
}
trap cleanup EXIT
# GNOME Shell aborts without logind on the system bus (lib/system_bus.sh).
. "${TESTS}/lib/system_bus.sh"
system_logind_ensure || exit 2
PIDS="${PIDS} ${SYSTEM_LOGIND_PID}"

mkdir -p "${WORK}/bin"
gcc -Wall -Wextra -Werror -O1 -o "${WORK}/bin/lswt" "${TESTS}/foreign_toplevel_probe.c" -lwayland-client \
	|| { echo "ENVIRONMENT: the foreign-toplevel probe does not build" >&2; exit 2; }
export PATH="${WORK}/bin:${PATH}"
command -v lswt >/dev/null 2>&1 || missing "the built lswt probe"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
FAILED=0

new_runtime() {
	local dir="${WORK}/run-$1"
	mkdir -m 700 "${dir}" && printf '%s' "${dir}"
}

# Waits up to 15 s for a file to appear.
wait_for() {
	local tries=0
	until [ -e "$1" ]; do
		tries=$((tries + 1))
		[ "${tries}" -le 150 ] || return 1
		sleep 0.1
	done
}

run_case() {
	local name="$1"
	shift
	echo "== ${name}"
	if "$@"; then echo "CASE ${name} PASS"; else echo "CASE ${name} FAIL"; FAILED=1; fi
}

sway_case() {
	local runtime
	runtime="$(new_runtime sway)" || return 1
	printf 'output HEADLESS-1 resolution 800x600\n' >"${WORK}/sway.conf"
	XDG_RUNTIME_DIR="${runtime}" sway -c "${WORK}/sway.conf" >"${WORK}/sway.log" 2>&1 &
	PIDS="${PIDS} $!"
	wait_for "${runtime}/wayland-1" || { echo "sway did not start"; return 1; }
	sleep 0.5
	local socket
	socket="$(ls "${runtime}"/sway-ipc.*.sock)" || return 1
	# sway keeps a workspace only while it holds a window: one per workspace.
	for workspace in 1 2 3; do
		XDG_RUNTIME_DIR="${runtime}" SWAYSOCK="${socket}" swaymsg "workspace ${workspace}; exec foot sleep 600" >/dev/null || return 1
		sleep 1
	done
	XDG_RUNTIME_DIR="${runtime}" SWAYSOCK="${socket}" swaymsg "workspace 1" >/dev/null || return 1
	XDG_RUNTIME_DIR="${runtime}" SWAYSOCK="${socket}" WAYLAND_DISPLAY=wayland-1 XDG_SESSION_TYPE=wayland \
		XDG_CURRENT_DESKTOP=sway luajit "${TESTS}/run_wayland_desktop_changes.lua" "${DRIVER_ROOT}" sway
}

# KWin's binary carries cap_sys_resource, which a container without that
# capability refuses to exec (EPERM); a private copy runs without it. It keeps
# its name: the KWin QPA plugin loads only into a process named kwin_wayland.
kde_case() {
	local runtime
	runtime="$(new_runtime kde)" || return 1
	mkdir -p "${WORK}/kwin" && cp "$(command -v kwin_wayland)" "${WORK}/kwin/kwin_wayland" || return 1
	XDG_RUNTIME_DIR="${runtime}" dbus-run-session -- bash -c '
		"$1/kwin/kwin_wayland" --virtual --socket wayland-kde --no-lockscreen --no-global-shortcuts \
			>"$1/kwin.log" 2>&1 &
		for _ in $(seq 150); do qdbus org.kde.KWin /KWin >/dev/null 2>&1 && break; sleep 0.1; done
		qdbus org.kde.KWin /KWin >/dev/null 2>&1 || { echo "KWin did not start"; exit 1; }
		echo "KWIN $("$1/kwin/kwin_wayland" --version 2>/dev/null)"
		for name in two three; do
			qdbus org.kde.KWin /VirtualDesktopManager org.kde.KWin.VirtualDesktopManager.createDesktop 9 "${name}" >/dev/null
		done
		export WAYLAND_DISPLAY=wayland-kde XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE
		luajit "$2/run_wayland_desktop_changes.lua" "$3" kde && luajit "$2/run_wayland_focus_lswt.lua" "$3" kde
	' _ "${WORK}" "${TESTS}" "${DRIVER_ROOT}" 2>&1 | grep -v "Failed to set fd limit"
	return "${PIPESTATUS[0]}"
}

gnome_case() {
	local runtime
	runtime="$(new_runtime gnome)" || return 1
	XDG_RUNTIME_DIR="${runtime}" dbus-run-session -- bash -c '
		gnome-shell --headless --wayland --no-x11 --virtual-monitor 800x600 --wayland-display wayland-gnome \
			>"$1/gnome-shell.log" 2>&1 &
		for _ in $(seq 300); do
			gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
				--method org.freedesktop.DBus.Properties.Get org.gnome.Shell ShellVersion >"$1/gnome-version" 2>/dev/null && break
			sleep 0.1
		done
		[ -s "$1/gnome-version" ] || { echo "GNOME Shell did not start"; exit 1; }
		echo "GNOME_SHELL $(cat "$1/gnome-version")"
		export WAYLAND_DISPLAY=wayland-gnome XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
		luajit "$2/run_wayland_desktop_changes.lua" "$3" gnome && luajit "$2/run_wayland_focus_lswt.lua" "$3" gnome
	' _ "${WORK}" "${TESTS}" "${DRIVER_ROOT}" 2>&1 | grep -v "Failed to set fd limit\|dbus-daemon\["
	return "${PIPESTATUS[0]}"
}

labwc_case() {
	local runtime
	runtime="$(new_runtime labwc)" || return 1
	XDG_RUNTIME_DIR="${runtime}" labwc >"${WORK}/labwc.log" 2>&1 &
	PIDS="${PIDS} $!"
	wait_for "${runtime}/wayland-0" || { echo "labwc did not start"; return 1; }
	sleep 0.5
	for app in ergopti.alpha ergopti.beta; do
		XDG_RUNTIME_DIR="${runtime}" WAYLAND_DISPLAY=wayland-0 foot --app-id="${app}" --title "${app} window" \
			sleep 600 >/dev/null 2>&1 &
		PIDS="${PIDS} $!"
		sleep 1
	done
	echo "LISTING $(XDG_RUNTIME_DIR="${runtime}" WAYLAND_DISPLAY=wayland-0 lswt -j)"
	XDG_RUNTIME_DIR="${runtime}" WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=labwc:wlroots \
		luajit "${TESTS}/run_wayland_focus_lswt.lua" "${DRIVER_ROOT}" labwc ergopti.alpha ergopti.beta
}

echo "VERSIONS sway=$(sway --version) labwc=$(labwc --version 2>&1 | head -1) foot=$(foot --version)"
run_case sway sway_case
run_case kde kde_case
run_case gnome gnome_case
run_case labwc labwc_case
exit "${FAILED}"
