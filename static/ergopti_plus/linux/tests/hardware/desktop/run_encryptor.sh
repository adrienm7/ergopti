#!/usr/bin/env bash
# tests/hardware/desktop/run_encryptor.sh
#
# ==============================================================================
# MODULE: Encryptor Container Proof
# DESCRIPTION:
# Runs run_encryptor.lua in a real X11 session (Xvfb, openbox, session bus).
# Needs xdotool, openssl, LuaJIT with lua-lgi and lua-luv, and GTK 3.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.
# ==============================================================================

set -u
. "$(dirname "$0")/lib/session.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-encryptor-XXXXXX")" || exit 2
desktop_session_run x11-openbox 96 env -u LUA_PATH -u LUA_CPATH \
	luajit "${DESKTOP_DRIVER_ROOT}/tests/hardware/desktop/run_encryptor.lua" "${scratch}" 2>"${scratch}/stderr"
status=$?
[ "${status}" -eq 0 ] || grep -vE "fd limit|dbus-daemon|SpiRegistry|libEGL" "${scratch}/stderr" | tail -20 >&2
rm -rf "${scratch}"
exit "${status}"
