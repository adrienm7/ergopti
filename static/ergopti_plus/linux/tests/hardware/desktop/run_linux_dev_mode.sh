#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_linux_dev_mode.sh
#
# Developer mode with the package installed, through the real
# tools/dev/run-linux-dev.sh and the real daemon it starts:
#   1. an installed ergopti-hotstrings.service is active under a REAL systemd
#      user manager, and the developer run stops it;
#   2. the tray appears (sni_host.py plays the panel's StatusNotifierWatcher);
#   3. a second run reports "already running" (the session lock) and exits;
#   4. a saved .lua of the driver restarts the daemon (new pid, ready again);
#   5. the tray's Reload row, clicked as a panel does, restarts it again.
#
# What is emulated, and why: the cloud kernel has no evdev and no uinput, so no
# keyboard node can exist. In a private mount namespace /proc/bus/input/devices
# lists one AT keyboard, /dev/input/event0 is a FIFO, and evdev_fifo_shim.c
# answers the evdev ioctls on that FIFO only (an idle keyboard). The installed
# unit runs a sleeping stand-in, since the point is that the developer run stops
# it. systemd --user needs /run/systemd/system (sd_booted): a tmpfs there, in
# the same namespace. Everything else is the distribution's or the repository's.
#
# Needs root, unshare, gcc, systemd, Xvfb, dbus-launch, at-spi2-core, openbox,
# python3.12 with python3-gi, luajit, lua-luv, lua-lgi, libayatana-appindicator.
# Exit 0 = every step passed; 1 = a failure; 2 = no environment.

set -u
DRIVER="$(cd "$(dirname "$0")/../../.." && pwd -P)" || exit 2
REPO="$(cd "${DRIVER}/../../.." && pwd -P)"
SELF="${DRIVER}/tests/hardware/desktop/run_linux_dev_mode.sh"
UNIT=ergopti-hotstrings.service
PY=python3.12
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need unshare
need gcc
need Xvfb
need dbus-launch
need openbox
need luajit
need systemctl
need "${PY}"
need pgrep
need pkill
need setsid
need /usr/lib/systemd/systemd
BUS_LAUNCHER=""
for candidate in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
	[ -x "${candidate}" ] && BUS_LAUNCHER="${candidate}" && break
done
[ -n "${BUS_LAUNCHER}" ] || { echo "ENVIRONMENT: at-spi-bus-launcher is missing" >&2; exit 2; }
# launch.sh asks pkexec for the input groups when the account lacks them, then
# re-enters them through sg; the account must already hold them here.
ACCOUNT_GROUPS=" $(id -nG "$(id -u)") "
for group in input uinput; do
	case "${ACCOUNT_GROUPS}" in *" ${group} "*) ;; *) echo "ENVIRONMENT: this account needs the ${group} group" >&2; exit 2 ;; esac
done

if [ "${ERGOPTI_DEV_NAMESPACE:-}" != 1 ]; then
	CREATED_INPUT=false
	[ -d /dev/input ] || { mkdir /dev/input && CREATED_INPUT=true; }
	env ERGOPTI_DEV_NAMESPACE=1 unshare -m bash "${SELF}" "$@"
	STATUS=$?
	"${CREATED_INPUT}" && rmdir /dev/input
	exit "${STATUS}"
fi

S="$(mktemp -d)"
export HOME="${S}/home" XDG_RUNTIME_DIR="${S}/run" TMPDIR="${S}/tmp"
mkdir -p "${HOME}/.config/systemd/user" "${XDG_RUNTIME_DIR}" "${TMPDIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
STATUS=0
PIDS=""
cleanup() {
	pkill -f "${DRIVER}/ergopti_hotstrings.lua" 2>/dev/null
	wait_for 15 '! pgrep -f "${DRIVER}/ergopti_hotstrings.lua" >/dev/null'
	# shellcheck disable=SC2086
	kill ${PIDS} 2>/dev/null
	rm -rf "${S}"
}
trap cleanup EXIT
check() {
	if eval "$2" 2>/dev/null; then echo "  ok   $1"; return; fi
	echo "  FAIL $1"
	STATUS=1
}
wait_for() {
	local limit="$1" ticks=0
	while ! eval "$2" 2>/dev/null; do
		ticks=$((ticks + 1))
		[ "${ticks}" -gt $((limit * 10)) ] && return 1
		sleep 0.1
	done
}
daemon_pid() { pgrep -f "luajit .*${DRIVER}/ergopti_hotstrings.lua" | head -n 1; }

# The keyboard node the kernel cannot provide here.
mount -t tmpfs none /dev/input || exit 2
mkfifo /dev/input/event0
sleep 100000 > /dev/input/event0 &
PIDS="${PIDS} $!"
cat > "${S}/devices" <<'DEVICES'
I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
P: Phys=isa0060/serio0/input0
S: Sysfs=/devices/platform/i8042/serio0/input/input0
U: Uniq=
H: Handlers=sysrq kbd event0 leds
B: PROP=0
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=7

DEVICES
mount --bind "${S}/devices" /proc/bus/input/devices || exit 2
gcc -shared -fPIC -O2 -Wall -o "${S}/evdev_fifo_shim.so" "${DRIVER}/tests/hardware/desktop/evdev_fifo_shim.c" -ldl || exit 2

# The installed package's unit, under a real user manager.
mount -t tmpfs none /run/systemd || exit 2
mkdir -p /run/systemd/system
sed "s|^ExecStart=.*|ExecStart=/bin/sleep infinity|" "${DRIVER}/ergopti-hotstrings.service" \
	> "${HOME}/.config/systemd/user/${UNIT}"
/usr/lib/systemd/systemd --user >"${S}/manager.log" 2>&1 &
PIDS="${PIDS} $!"
wait_for 10 '[ "$(systemctl --user is-system-running)" = running ] || [ "$(systemctl --user is-system-running)" = degraded ]' \
	|| { echo "ENVIRONMENT: systemd --user did not start" >&2; exit 2; }
systemctl --user start "${UNIT}"

# The desktop: X server, session bus, accessibility bus, window manager.
Xvfb :84 -screen 0 1024x768x24 >/dev/null 2>&1 &
PIDS="${PIDS} $!"
export DISPLAY=:84
eval "$(dbus-launch --sh-syntax)"
PIDS="${PIDS} ${DBUS_SESSION_BUS_PID}"
"${BUS_LAUNCHER}" --launch-immediately >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"

# One panel inspection per daemon generation: sni_host.py exits after it.
panel() {
	local name="$1"
	shift
	rm -f "${S}/${name}.ready"
	"${PY}" "${DRIVER}/tests/hardware/sni_host.py" --ready-file "${S}/${name}.ready" --timeout 60 --settle 3 \
		--expect-icon-file "$@" > "${S}/${name}.json" 2>&1 &
	PANEL=$!
	wait_for 10 '[ -f "${S}/${name}.ready" ]' || { echo "ENVIRONMENT: the StatusNotifier host never started" >&2; exit 2; }
}
# The daemon here speaks French (no locale configured), so its Reload row reads the fr label.
RELOAD_LABEL="$("${PY}" -c 'import json, sys; print(json.load(open(sys.argv[1]))["menu.global.reload"])' \
	"${DRIVER}/../_shared/core/i18n/data/locales/fr.json")"
[ -n "${RELOAD_LABEL}" ] || { echo "ENVIRONMENT: no Reload label in fr.json" >&2; exit 2; }

echo "developer run with the package installed"
check "the installed unit is active before the run" "systemctl --user is-active --quiet ${UNIT}"
panel first --expect-label "${RELOAD_LABEL}"
LD_PRELOAD="${S}/evdev_fifo_shim.so" setsid bash "${REPO}/tools/dev/run-linux-dev.sh" --no-grab \
	< /dev/null > "${S}/dev.log" 2>&1 &
check "the developer run stopped the installed unit" "wait_for 20 '! systemctl --user is-active --quiet ${UNIT}'"
check "the run said it stops the unit" "grep -q 'Stopping the installed ${UNIT}' '${S}/dev.log'"
check "the tray appears (item registered, icon file, Reload row)" "wait ${PANEL}"
FIRST="$(daemon_pid)"
check "the daemon runs (pid ${FIRST})" "[ -n '${FIRST}' ]"

echo "second developer run"
LD_PRELOAD="${S}/evdev_fifo_shim.so" bash "${REPO}/tools/dev/run-linux-dev.sh" --no-grab \
	< /dev/null > "${S}/second.log" 2>&1
SECOND_STATUS=$?
# A tray start that finds the lock held is expected (autostart racing the unit) and exits 0.
check "the second run returns at once (exit ${SECOND_STATUS}, a tray start)" "[ ${SECOND_STATUS} -eq 0 ]"
check "it reports « already running » on the session lock" \
	"grep -q 'tourne déjà dans cette session\|is already running in this session' '${S}/second.log' && grep -q 'ergopti.lock' '${S}/second.log'"
check "the first daemon still runs" "[ \"\$(daemon_pid)\" = '${FIRST}' ]"

echo "a saved .lua"
panel saved --expect-label "${RELOAD_LABEL}"
SAVED="${DRIVER}/core/lifecycle/engine/dev_source.lua"
cp -p "${SAVED}" "${S}/saved.lua"
cat "${S}/saved.lua" > "${SAVED}"
check "the daemon restarted (new pid)" "wait_for 40 '[ -n \"\$(daemon_pid)\" ] && [ \"\$(daemon_pid)\" != ${FIRST} ]'"
SAVED_PID="$(daemon_pid)"
check "the restarted daemon shows its tray" "wait ${PANEL}"
check "the saved file is unchanged" "cmp -s '${S}/saved.lua' '${SAVED}'"

echo "the tray's Reload"
panel reload --click-label "${RELOAD_LABEL}"
check "the Reload row was clicked" "wait ${PANEL} && grep -q '\"clicked\"' '${S}/reload.json'"
check "the daemon restarted (new pid)" "wait_for 40 '[ -n \"\$(daemon_pid)\" ] && [ \"\$(daemon_pid)\" != ${SAVED_PID} ]'"
RELOADED="$(daemon_pid)"
panel after --expect-label "${RELOAD_LABEL}"
check "the reloaded daemon shows its tray (pid ${RELOADED})" "wait ${PANEL}"
check "exactly one daemon runs" "[ \"\$(pgrep -fc \"luajit .*${DRIVER}/ergopti_hotstrings.lua\")\" = 1 ]"
check "the installed unit stays stopped" "! systemctl --user is-active --quiet ${UNIT}"
if [ "${STATUS}" != 0 ]; then
	for log in dev second; do echo "--- ${log}.log"; grep -v 'DEBUG\|TRACE' "${S}/${log}.log" | tail -n 15; done
	for json in first saved reload after; do echo "--- ${json}.json"; grep -A3 failures "${S}/${json}.json"; done
fi
exit "${STATUS}"
