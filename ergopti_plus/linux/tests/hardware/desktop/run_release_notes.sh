#!/usr/bin/env bash
# tests/hardware/desktop/run_release_notes.sh
#
# ==============================================================================
# MODULE: Release Notes Pane Container Proof
# DESCRIPTION:
# Runs run_release_notes.lua on X11 (openbox) and on GNOME Shell's Wayland,
# with an xdg-open recorder first on PATH. Needs what run_window_toggle.sh
# needs. Exit 0 = every session held; 1 = a failure; 2 = no environment.
# ==============================================================================

set -u
. "$(dirname "$0")/lib/session.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-notes-XXXXXX")" || exit 2
mkdir "${scratch}/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/opened"\n' "${scratch}" > "${scratch}/bin/xdg-open"
chmod 755 "${scratch}/bin/xdg-open"
overall=0
display=88
for kind in x11-openbox gnome-wayland; do
	rm -f "${scratch}/opened"
	PATH="${scratch}/bin:${PATH}" desktop_session_run "${kind}" "${display}" \
		luajit tests/hardware/desktop/run_release_notes.lua "${scratch}/opened" 2>"${scratch}/stderr"
	status=$?
	if [ "${status}" -ne 0 ]; then
		grep -vE "fd limit|dbus-daemon|SpiRegistry|libEGL|Activat" "${scratch}/stderr" | tail -20 >&2
		[ "${overall}" -eq 1 ] || overall="${status}"
	fi
	display=$((display + 1))
done
rm -rf "${scratch}"
exit "${overall}"
