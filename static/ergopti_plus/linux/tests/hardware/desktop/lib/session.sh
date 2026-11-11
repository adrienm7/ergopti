#!/usr/bin/env bash
# tests/hardware/desktop/lib/session.sh
#
# ==============================================================================
# MODULE: Headless Desktop Sessions For The Container Proofs
# DESCRIPTION:
# Sourced by the tests/hardware/desktop launchers. desktop_session_run starts one real
# desktop session in a private runtime folder and runs a command inside it,
# with the daemon's Lua paths, from the driver root:
#   x11-openbox    Xvfb, a session bus, openbox.
#   x11-xfwm4      Xvfb, a session bus, xfwm4 (Xfce's window manager).
#   gnome-wayland  GNOME Shell's own Wayland compositor, nested in Xvfb (the
#                  host only lends it a keyboard and a screen; clients reach
#                  it through WAYLAND_DISPLAY alone, without Xwayland). The
#                  overview GNOME opens at login is closed first.
# The maintainer decision of 2026-11-10 (docs/memory/maintainer-decisions.md)
# lets such a session close a Linux check that needs a desktop.
# ERGOPTI_PROOF_HOST_DISPLAY names the Xvfb display, through which xdotool
# types on the session's real keyboard (the nested compositor's too).
# Exit 2 from desktop_session_run means the session could not start.
# ==============================================================================

DESKTOP_DRIVER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
. "$(dirname "${BASH_SOURCE[0]}")/system_bus.sh"

# Runs "$@" inside the named session; prints nothing of its own on success.
desktop_session_run() {
	local kind="$1" display="$2"
	shift 2
	local tools="Xvfb dbus-run-session luajit xdotool"
	case "${kind}" in
		x11-openbox) tools="${tools} openbox" ;;
		x11-xfwm4) tools="${tools} xfwm4" ;;
		gnome-wayland) tools="${tools} gnome-shell gdbus" ;;
		*) echo "ENVIRONMENT: unknown session ${kind}" >&2; return 2 ;;
	esac
	local tool
	for tool in ${tools}; do
		command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; return 2; }
	done
	local logind=""
	if [ "${kind}" = gnome-wayland ]; then
		system_logind_ensure || return 2
		logind="${SYSTEM_LOGIND_PID}"
	fi
	local runtime
	runtime="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-desktop-XXXXXX")" || return 2
	chmod 700 "${runtime}"
	Xvfb ":${display}" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
	local xvfb=$!
	sleep 1
	(
		cd "${DESKTOP_DRIVER_ROOT}" || exit 2
		export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
		export LUA_PATH="${LUA_PATH};/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"
		export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
		export XDG_RUNTIME_DIR="${runtime}" HOME="${runtime}/home" DISPLAY=":${display}"
		export XDG_CONFIG_HOME="${runtime}/home/.config" XDG_DATA_HOME="${runtime}/home/.local/share"
		export ERGOPTI_PROOF_SESSION="${kind}" ERGOPTI_PROOF_RUNTIME="${runtime}" ERGOPTI_PROOF_HOST_DISPLAY=":${display}"
		mkdir -p "${HOME}"
		exec dbus-run-session -- bash -c '
			kind="$1"; shift
			case "${kind}" in
				x11-openbox) openbox >/dev/null 2>&1 & ;;
				x11-xfwm4) xfwm4 --compositor=off >/dev/null 2>&1 & ;;
				gnome-wayland)
					gnome-shell --nested --wayland --no-x11 --wayland-display ergopti-proof \
						>"${ERGOPTI_PROOF_RUNTIME}/compositor.log" 2>&1 &
					for _ in $(seq 1 100); do
						gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
							--method org.freedesktop.DBus.Properties.Set org.gnome.Shell OverviewActive "<false>" \
							>/dev/null 2>&1 && break
						sleep 0.2
					done
					[ -S "${XDG_RUNTIME_DIR}/ergopti-proof" ] || { echo "ENVIRONMENT: GNOME Shell did not start" >&2; exit 2; }
					unset DISPLAY
					export WAYLAND_DISPLAY=ergopti-proof GDK_BACKEND=wayland XDG_SESSION_TYPE=wayland
					export XDG_CURRENT_DESKTOP=GNOME
					;;
			esac
			compositor=$!
			sleep 1
			"$@"
			status=$?
			kill "${compositor}" 2>/dev/null
			exit "${status}"
		' desktop-session "${kind}" "$@"
	)
	local status=$?
	kill "${xvfb}" ${logind} 2>/dev/null
	wait "${xvfb}" ${logind} 2>/dev/null
	rm -rf "${runtime}"
	return "${status}"
}
