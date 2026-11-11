#!/usr/bin/env bash
# tests/hardware/run_input_sources_live.sh
#
# ==============================================================================
# MODULE: Headless Desktop Sessions For The Input Sources Proof
# DESCRIPTION:
# Starts one real desktop session, headless and private (its own D-Bus session
# bus, runtime folder, HOME and config), with two keyboard layouts (us, then
# fr), and runs run_input_sources_live.lua inside it:
#
#   gnome      GNOME Shell on Wayland (--headless --virtual-monitor). It needs
#              logind on the system bus: python-dbusmock's logind template
#              runs on a private bus named as the system bus. A RemoteDesktop
#              session adds the virtual keyboard XWayland needs to receive
#              mutter's keymap.
#   kde        KWin on Wayland (--virtual), which serves org.kde.keyboard
#              /Layouts itself.
#   kde-x11    KWin on Xvfb with kded's keyboard module (org.kde.keyboard).
#   x11        openbox on Xvfb, layouts from setxkbmap.
#   sway       sway on its headless backend: no supported switch.
#
# The active layout is read back from the X server or XWayland
# (lib/x11_active_layout.lua), on KWin Wayland from KWin's own active index
# (lib/kde_active_layout.sh). Exit 0 = every check held, 1 = a check failed,
# 2 = a prerequisite is missing. All processes and files are removed on exit.
# ==============================================================================

set -u
cd "$(dirname "$0")/../.." || exit 2
DESKTOP="${1:-}"
# The script run inside the session (default: the input sources proof).
case "${DESKTOP}" in gnome | kde | kde-x11 | x11 | sway) ;; *)
	echo "usage: $0 gnome|kde|kde-x11|x11|sway" >&2
	exit 2
	;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }; }
for tool in luajit dbus-launch xkbcomp gdbus; do need "${tool}"; done

SCRATCH="$(mktemp -d /tmp/ergopti-input-sources-XXXXXX)"
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
unset DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION
eval "$(dbus-launch --sh-syntax)"
export ERGOPTI_LIVE_ACTIVE_CMD="luajit tests/hardware/lib/x11_active_layout.lua"
# us types q on <AD01>, fr types a: the layouts in the session's order.
export ERGOPTI_LIVE_LAYOUTS="q a"

start_xvfb() {
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
}

# Waits for an XWayland the compositor started and exports its DISPLAY.
await_xwayland() {
	local before="$1"
	for _ in $(seq 1 100); do
		for socket in /tmp/.X11-unix/X*; do
			case " ${before} " in *" ${socket} "*) continue ;; esac
			[ -S "${socket}" ] && export DISPLAY=":${socket##*/X}" && return 0
		done
		sleep 0.1
	done
	echo "ENVIRONMENT: no XWayland appeared" >&2
	exit 2
}

case "${DESKTOP}" in
x11)
	need Xvfb; need openbox; need setxkbmap
	start_xvfb
	openbox >/dev/null 2>&1 &
	PIDS="${PIDS} $!"
	setxkbmap -layout us,fr
	export XDG_SESSION_TYPE=x11 ERGOPTI_LIVE_DESKTOP=x11
	;;
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
	gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us'), ('xkb', 'fr')]"
	before="$(echo /tmp/.X11-unix/X*)"
	# ERGOPTI_LIVE_GNOME_UNSAFE=1 lets a diagnostic ask the shell its own view (Eval).
	unsafe=""
	[ -n "${ERGOPTI_LIVE_GNOME_UNSAFE:-}" ] && unsafe="--unsafe-mode"
	XDG_SESSION_TYPE=wayland gnome-shell ${unsafe} --headless --wayland --virtual-monitor 1280x800 >"${SCRATCH}/shell.log" 2>&1 &
	PIDS="${PIDS} $!"
	await_xwayland "${before}"
	for _ in $(seq 1 100); do
		XAUTHORITY="$(ls "${XDG_RUNTIME_DIR}"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)"
		[ -n "${XAUTHORITY}" ] && break
		sleep 0.1
	done
	export XAUTHORITY
	# The virtual keyboard mutter hands its keymap to XWayland through.
	mkfifo "${SCRATCH}/keyboard.in"
	"${python_mock}" tests/hardware/lib/mutter_virtual_keyboard.py <"${SCRATCH}/keyboard.in" >"${SCRATCH}/keyboard.out" 2>&1 &
	PIDS="${PIDS} $!"
	exec 8>"${SCRATCH}/keyboard.in"
	for _ in $(seq 1 100); do grep -q READY "${SCRATCH}/keyboard.out" 2>/dev/null && break; sleep 0.1; done
	grep -q READY "${SCRATCH}/keyboard.out" || { echo "ENVIRONMENT: no mutter virtual keyboard" >&2; exit 2; }
	echo "key 42 1" >&8
	echo "key 42 0" >&8
	sleep 1
	export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME ERGOPTI_LIVE_DESKTOP=gnome
	;;
kde)
	need kwin_wayland; need gdbus
	printf '[Layout]\nLayoutList=us,fr\nUse=true\n' >"${XDG_CONFIG_HOME}/kxkbrc"
	before="$(echo /tmp/.X11-unix/X*)"
	XDG_SESSION_TYPE=wayland kwin_wayland --virtual --xwayland --width 1280 --height 800 >"${SCRATCH}/kwin.log" 2>&1 &
	PIDS="${PIDS} $!"
	await_xwayland "${before}"
	for _ in $(seq 1 100); do
		gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
			--method org.kde.KeyboardLayouts.getLayout >/dev/null 2>&1 && break
		sleep 0.1
	done
	XAUTHORITY="$(ls "${XDG_RUNTIME_DIR}"/xauth_* 2>/dev/null | head -1)"
	export XAUTHORITY XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 ERGOPTI_LIVE_DESKTOP=kde
	# A headless XWayland gets no group change without a focused client: the
	# layout KWin applies is read from KWin itself, named by the session order.
	export ERGOPTI_LIVE_ACTIVE_CMD="sh tests/hardware/lib/kde_active_layout.sh"
	;;
kde-x11)
	need Xvfb; need kwin_x11; need kded6; need gdbus
	printf '[Layout]\nLayoutList=us,fr\nUse=true\n' >"${XDG_CONFIG_HOME}/kxkbrc"
	start_xvfb
	# At login kcminit applies kxkbrc to the server; kded's keyboard module
	# then lists the server's layouts.
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
	export ERGOPTI_LIVE_DESKTOP=kde
	;;
sway)
	need sway
	export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
	printf 'input * xkb_layout "us,fr"\n' >"${SCRATCH}/sway.conf"
	sway -c "${SCRATCH}/sway.conf" >"${SCRATCH}/sway.log" 2>&1 &
	PIDS="${PIDS} $!"
	for _ in $(seq 1 100); do ls "${XDG_RUNTIME_DIR}"/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
	WAYLAND_DISPLAY="$(basename "$(ls "${XDG_RUNTIME_DIR}"/wayland-? | head -1)")"
	export WAYLAND_DISPLAY XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=sway ERGOPTI_LIVE_DESKTOP=unsupported
	unset DISPLAY
	;;
esac

luajit "${2:-tests/hardware/run_input_sources_live.lua}"
