#!/usr/bin/env bash
# tests/hardware/run_x11_reapply_live.sh
#
# ==============================================================================
# MODULE: Desktop Re-Apply Of An X11 User-Tree Layout (W4)
# DESCRIPTION:
# Answers W4 of docs/design/layout-option-emulation.md on a real desktop
# session under X11, headless and private (its own buses, HOME and config):
#
#   gnome   GNOME Shell --x11 on Xvfb (logind from python-dbusmock).
#   kde     kwin_x11 on Xvfb with kded's keyboard module.
#
# The registry's Bépo is converted, installed in the user XKB tree and loaded
# into the server by the real installer (apply-x11). The server keymap is then
# read after each desktop event: nothing, a layout switch of the desktop, a new
# keyboard (an XInput master, as a hotplug adds a device) and, on GNOME, an
# input-sources setting change. Each check states the behaviour observed on
# 2026-11-11 (GNOME Shell 46, Plasma 6.6.4): the desktop keeps the loaded
# keymap on a switch and puts its own layout list back on a new keyboard.
# Then run_x11_reapply_daemon.lua checks that the daemon loads the layout again
# after such a replacement.
# Exit 0 = the desktop behaved as stated, 1 = it did not, 2 = a prerequisite is
# missing. Run it as the desktop user: the installer writes that user's tree.
# ==============================================================================

set -u
cd "$(dirname "$0")/../.." || exit 2
DESKTOP="${1:-}"
case "${DESKTOP}" in gnome | kde) ;; *)
	echo "usage: $0 gnome|kde" >&2
	exit 2
	;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }; }
need Xvfb; need xkbcomp; need setxkbmap; need xinput; need dbus-launch; need gdbus; need python3

INSTALLER_DIR="$(cd ../../ergopti/linux/xkb_installation && pwd)"
SCRATCH="$(mktemp -d /tmp/ergopti-x11-reapply-XXXXXX)"
PIDS=""
cleanup() {
	# shellcheck disable=SC2086
	[ -n "${PIDS}" ] && kill ${PIDS} 2>/dev/null
	[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "${DBUS_SESSION_BUS_PID}" 2>/dev/null
	[ -n "${SYSTEM_BUS_PID:-}" ] && kill "${SYSTEM_BUS_PID}" 2>/dev/null
	rm -rf "${SCRATCH}"
}
trap cleanup EXIT
mkdir -p "${SCRATCH}/home/.config" "${SCRATCH}/runtime" /tmp/.X11-unix
chmod 700 "${SCRATCH}/runtime"
export HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/home/.config" XDG_RUNTIME_DIR="${SCRATCH}/runtime"
export ERGOPTI_XKB_USER_HOME="${HOME}"
unset DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION

exec 9>"${SCRATCH}/display"
Xvfb -displayfd 9 -noreset -nolisten tcp -screen 0 1280x800x24 >/dev/null 2>&1 &
PIDS="${PIDS} $!"
exec 9>&-
for _ in $(seq 1 100); do
	[ -s "${SCRATCH}/display" ] && break
	sleep 0.1
done
[ -s "${SCRATCH}/display" ] || { echo "ENVIRONMENT: Xvfb did not start" >&2; exit 2; }
export DISPLAY=":$(head -1 "${SCRATCH}/display")"
eval "$(dbus-launch --sh-syntax)"

case "${DESKTOP}" in
gnome)
	need gnome-shell; need gsettings
	python_mock=""
	for candidate in python3 /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.13; do
		if "${candidate}" -c "import dbusmock, gi" >/dev/null 2>&1; then python_mock="${candidate}" && break; fi
	done
	[ -n "${python_mock}" ] || { echo "ENVIRONMENT: python-dbusmock with GObject bindings is missing" >&2; exit 2; }
	session_bus="${DBUS_SESSION_BUS_ADDRESS}" session_pid="${DBUS_SESSION_BUS_PID}"
	eval "$(dbus-launch --sh-syntax)"
	export DBUS_SYSTEM_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}"
	SYSTEM_BUS_PID="${DBUS_SESSION_BUS_PID}"
	export DBUS_SESSION_BUS_ADDRESS="${session_bus}" DBUS_SESSION_BUS_PID="${session_pid}"
	"${python_mock}" -m dbusmock --system --template logind >/dev/null 2>&1 &
	PIDS="${PIDS} $!"
	sleep 1
	gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'fr')]"
	# --unsafe-mode: the desktop's own layout switch is driven through Eval.
	XDG_SESSION_TYPE=x11 gnome-shell --unsafe-mode --x11 >"${SCRATCH}/shell.log" 2>&1 &
	PIDS="${PIDS} $!"
	for _ in $(seq 1 200); do
		grep -q "GNOME Shell started" "${SCRATCH}/shell.log" 2>/dev/null && break
		sleep 0.1
	done
	grep -q "GNOME Shell started" "${SCRATCH}/shell.log" || { echo "ENVIRONMENT: GNOME Shell did not start" >&2; exit 2; }
	export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=GNOME
	switch_layout() {
		gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
			'Main.panel.statusArea.keyboard._inputSourceManager.inputSources[1].activate(true)' >/dev/null
	}
	;;
kde)
	need kwin_x11; need kded6
	printf '[Layout]\nLayoutList=us,fr\nUse=true\n' >"${XDG_CONFIG_HOME}/kxkbrc"
	setxkbmap -layout us,fr
	export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6
	kwin_x11 >"${SCRATCH}/kwin.log" 2>&1 &
	PIDS="${PIDS} $!"
	kded6 >"${SCRATCH}/kded.log" 2>&1 &
	PIDS="${PIDS} $!"
	# Plasma's session startup loads the keyboard module; a bare kded loads none.
	for _ in $(seq 1 100); do
		gdbus call --session --dest org.kde.kded6 --object-path /kded \
			--method org.kde.kded6.loadModule keyboard >/dev/null 2>&1 && break
		sleep 0.1
	done
	for _ in $(seq 1 200); do
		gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
			--method org.kde.KeyboardLayouts.getLayout >/dev/null 2>&1 && break
		sleep 0.1
	done
	switch_layout() {
		gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
			--method org.kde.KeyboardLayouts.setLayout 1 >/dev/null
	}
	;;
esac

FAILURES=0
CHECKS=0
check() {
	CHECKS=$((CHECKS + 1))
	if [ "$1" = 0 ]; then echo "  ok   $2"; else FAILURES=$((FAILURES + 1)); echo "  FAIL $2"; fi
}
held() { xkbcomp -xkb "${DISPLAY}" - 2>/dev/null | sed -n 's/.*xkb_symbols "\([^"]*\)".*/\1/p'; }
holds_bepo() { case "$(held)" in *+bepo+*) return 0 ;; *) return 1 ;; esac; }
installer() { python3 "${INSTALLER_DIR}/user_layout_installer.py" "$@" 2>/dev/null | grep -q '"ok": true'; }
apply() { installer apply-x11 --layout-id bepo; }

echo "=== W4: does ${DESKTOP} under X11 re-apply its own layout? ==="
python3 -c "import sys; from pathlib import Path; sys.path[:0] = [sys.argv[1] + '/tests', sys.argv[1]]
from test_user_layout_installer import convert; convert('bepo', Path(sys.argv[2]))" \
	"${INSTALLER_DIR}" "${SCRATCH}/bepo" >/dev/null 2>&1
installer install --layout-id bepo --display-name bepo --source-dir "${SCRATCH}/bepo" --language fr --allow-xorg
check $? "Bépo is installed in the user tree"
apply
check $? "apply-x11 loads it into the server ($(held))"
sleep 3
holds_bepo
check $? "with no desktop event the server keeps it ($(held))"
switch_layout
sleep 2
holds_bepo
check $? "a layout switch of the desktop keeps it ($(held))"
apply
xinput create-master w4probe
sleep 3
holds_bepo
check $((1 - $?)) "W4: a new keyboard makes the desktop put its own layouts back ($(held))"
# The probe keyboard stays: kwin_x11 6.6.4 crashes when a master is removed,
# and a Plasma without KWin no longer re-applies its layouts.
if [ "${DESKTOP}" = gnome ]; then
	apply
	gsettings set org.gnome.desktop.input-sources xkb-options "['compose:ralt']"
	sleep 2
	holds_bepo
	check $((1 - $?)) "W4: an input-sources setting change does too ($(held))"
fi
echo "=== ${CHECKS} check(s), ${FAILURES} failure(s) ==="
# The daemon's own answer: its layout manager arms the re-apply, which loads
# the layout again after the desktop replaced it.
luajit tests/hardware/run_x11_reapply_daemon.lua
daemon=$?
[ "${FAILURES}" = 0 ] && [ "${daemon}" = 0 ]
