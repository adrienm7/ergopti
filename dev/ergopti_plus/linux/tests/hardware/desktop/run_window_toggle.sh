#!/usr/bin/env bash
# tests/hardware/desktop/run_window_toggle.sh
#
# ==============================================================================
# MODULE: Window-Toggle Container Proof
# DESCRIPTION:
# Runs run_window_toggle.lua in three real sessions: X11 under openbox, X11
# under xfwm4, and GNOME Shell on Wayland. Needs root-free Xvfb, openbox,
# xfwm4, gnome-shell, dbus-run-session, LuaJIT with lua-lgi and lua-luv, and
# WebKit2GTK 4.1's introspection data (gir1.2-webkit2-4.1).
# USAGE: bash tests/hardware/desktop/run_window_toggle.sh [session...]
# Exit 0 = every session held; 1 = a failure; 2 = no environment.
# ==============================================================================

set -u
. "$(dirname "$0")/lib/session.sh"
SESSIONS=("$@")
[ "${#SESSIONS[@]}" -gt 0 ] || SESSIONS=(x11-openbox x11-xfwm4 gnome-wayland)
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-toggle-XXXXXX")" || exit 2
overall=0
display=93
for kind in "${SESSIONS[@]}"; do
	desktop_session_run "${kind}" "${display}" \
		luajit tests/hardware/desktop/run_window_toggle.lua tests/hardware/desktop/cover_window.lua "${scratch}" 2>"${scratch}/${kind}.stderr"
	status=$?
	if [ "${status}" -ne 0 ]; then
		grep -E "ENVIRONMENT|ERROR" "${scratch}/${kind}.stderr" >&2
		[ "${overall}" -eq 1 ] || overall="${status}"
	fi
	display=$((display + 1))
done
rm -rf "${scratch}"
exit "${overall}"
