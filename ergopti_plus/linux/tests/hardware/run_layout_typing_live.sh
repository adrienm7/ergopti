#!/usr/bin/env bash
# tests/hardware/run_layout_typing_live.sh
#
# ==============================================================================
# MODULE: Owned Session For The Live Layout Typing Proof
# DESCRIPTION:
# Starts a private X server (Xvfb, -noreset so an uploaded keymap survives its
# one-shot client), a private D-Bus session with the AT-SPI bus, openbox for
# focus, loads the AZERTY (fr) XKB layout with setxkbmap, then runs
# run_layout_typing_live.lua, which types through the daemon's real chain into
# mousepad (GTK) and kwrite (Qt) and reads their text back through AT-SPI.
#
# Everything lives under one temporary folder (HOME, XDG_CONFIG_HOME, the user
# XKB tree, ~/.XCompose); it and every process started here are removed on exit.
# Exit 0 = every check held, 1 = a check failed, 2 = a prerequisite is missing.
# The receipt is copied to $1 when a path is given.
# ==============================================================================

set -u
cd "$(dirname "$0")/../.." || exit 2

RECEIPT_OUT="${1:-}"
BUS_LAUNCHER=""
for candidate in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
	[ -x "${candidate}" ] && BUS_LAUNCHER="${candidate}" && break
done
for tool in Xvfb setxkbmap xkbcomp xdotool xclip dbus-launch openbox luajit mousepad kwrite python3; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
[ -n "${BUS_LAUNCHER}" ] || { echo "ENVIRONMENT: at-spi-bus-launcher is missing" >&2; exit 2; }
# The distribution's interpreter holds the GObject bindings; a newer python3
# first on PATH usually does not.
ATSPI_PYTHON=""
for candidate in python3 /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.13 /usr/bin/python3.11; do
	if "${candidate}" -c "import gi; gi.require_version('Atspi', '2.0'); from gi.repository import Atspi" >/dev/null 2>&1; then
		ATSPI_PYTHON="${candidate}" && break
	fi
done
[ -n "${ATSPI_PYTHON}" ] || { echo "ENVIRONMENT: no python3 with the Atspi GObject bindings" >&2; exit 2; }

SCRATCH="$(mktemp -d /tmp/ergopti-layout-typing-XXXXXX)"
PIDS=""
cleanup() {
	# shellcheck disable=SC2086
	[ -n "${PIDS}" ] && kill ${PIDS} 2>/dev/null
	[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "${DBUS_SESSION_BUS_PID}" 2>/dev/null
	if [ -n "${ERGOPTI_LIVE_KEEP:-}" ]; then echo "scratch kept: ${SCRATCH}" >&2; else rm -rf "${SCRATCH}"; fi
}
trap cleanup EXIT
mkdir -p "${SCRATCH}/home" "${SCRATCH}/config/ergopti" "${SCRATCH}/runtime"
chmod 700 "${SCRATCH}/runtime"

exec 9>"${SCRATCH}/display"
Xvfb -displayfd 9 -noreset -nolisten tcp -screen 0 1280x800x24 >/dev/null 2>&1 &
PIDS="$!"
exec 9>&-
for _ in $(seq 1 100); do
	DISPLAY_NUMBER="$(head -1 "${SCRATCH}/display" 2>/dev/null)"
	[ -n "${DISPLAY_NUMBER}" ] && break
	sleep 0.1
done
[ -n "${DISPLAY_NUMBER:-}" ] || { echo "ENVIRONMENT: Xvfb did not start" >&2; exit 2; }

export DISPLAY=":${DISPLAY_NUMBER}" HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/config"
export XDG_RUNTIME_DIR="${SCRATCH}/runtime" XDG_SESSION_TYPE=x11 ERGOPTI_XKB_USER_HOME="${SCRATCH}/home"
export GTK_MODULES=gail:atk-bridge QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 QT_ACCESSIBILITY=1 QT_QPA_PLATFORM=xcb
export NO_AT_BRIDGE=0 ERGOPTI_LIVE_SCRATCH="${SCRATCH}" ERGOPTI_LIVE_ATSPI_PYTHON="${ATSPI_PYTHON}"
unset WAYLAND_DISPLAY XDG_CURRENT_DESKTOP ERGOPTI_XKB_USER_ROOT
eval "$(dbus-launch --sh-syntax)"
"${BUS_LAUNCHER}" --launch-immediately >/dev/null 2>&1 &
PIDS="${PIDS} $!"
openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
setxkbmap -layout fr || { echo "ENVIRONMENT: setxkbmap cannot load the fr layout" >&2; exit 2; }
# A stopped editor is not a crash to recover from: no restore prompt on restart.
! command -v gsettings >/dev/null 2>&1 || gsettings set org.xfce.mousepad.preferences.file session-restore never 2>/dev/null

luajit tests/hardware/run_layout_typing_live.lua
STATUS=$?
if [ -n "${RECEIPT_OUT}" ] && [ -f "${SCRATCH}/receipt.txt" ]; then cp "${SCRATCH}/receipt.txt" "${RECEIPT_OUT}"; fi
exit "${STATUS}"
