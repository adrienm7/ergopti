#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/layouts/phys_live_guest.sh
#
# The recovery audit's live daemon scenarios ([PHYS-L]) on a real Linux host:
# a real kernel with /dev/uinput, systemd as PID 1 and a lingering user
# manager. run_phys_vm.sh boots such a host (an Ubuntu cloud VM) when the
# machine running it has neither; a GitHub-hosted Ubuntu runner can run this
# script directly as root.
#
#   1. install: the real install.sh, as an unprivileged sudoer whose user
#      manager is reachable, enables and starts ergopti-hotstrings.service;
#   2. session: the user manager restarts (the next login: the input and
#      uinput groups install.sh granted apply), an X server and a keyboard
#      (phys_keyboard.lua, uinput) stand in for the desktop and the hardware;
#      the unit's only change is a drop-in pinning --device to that keyboard,
#      because the finder rightly skips uinput sources as synthetic;
#   3. systemd restart: tools/control/request_driver_reload.sh asks the
#      running unit to reload; the restarter takes the unit path, the real
#      user manager restarts the unit, and the successor (a new MainPID in the
#      unit) completes the request; keys flow through the successor;
#   4. owned smoke deadline: phys_smoke_deadline.lua runs the INSTALLED async
#      installer against the installed root with a candidate whose --help
#      never returns, while the daemon keeps re-emitting keys (input latency
#      measured on its output device); the tree is restored and the unit
#      restarts on it;
#   5. relay restart: the same daemon started outside the unit takes the
#      detached relay, which waits for the old process to exit before it
#      starts the successor; the successor completes the request.
#
# Run as root. The checkout subset is at $ERGOPTI_SRC (default /src); compact
# receipts go to $ERGOPTI_PHYS_RECEIPTS (default /root/phys-receipts).
# Exit 0 = every check held; 1 = a check failed; 2 = no environment.

set -uo pipefail
SRC="${ERGOPTI_SRC:-/src}"
RECEIPTS="${ERGOPTI_PHYS_RECEIPTS:-/root/phys-receipts}"
PHYS_USER="ergopti-phys"
DISPLAY_NUMBER=":97"
RELOAD_TIMEOUT_SECONDS=120
# The 90th-percentile ceiling of one key through the daemon. Generous: the
# proof host may be an emulated CPU, where a single key can take two seconds;
# a held loop shows as missing keys and a p90 in seconds.
LATENCY_LIMIT_MS=1500
FAILURES=0
CHECKS=0
mkdir -p "${RECEIPTS}"
SUMMARY="${RECEIPTS}/summary.txt"
: > "${SUMMARY}"

say()     { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }
ok()      { CHECKS=$((CHECKS + 1)); say "  ok   $*"; }
fail()    { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); say "  FAIL $*"; }
check()   { local label="$1"; shift; if "$@"; then ok "${label}"; else fail "${label}"; fi; }
section() { say ""; say "=== $* ==="; }
environment() { echo "ENVIRONMENT: $*" >&2; exit 2; }
need() {
	command -v "$1" >/dev/null 2>&1 || environment "$1 is missing"
}

[ "$(id -u)" -eq 0 ] || environment "run as root"
[ "$(cat /proc/1/comm)" = "systemd" ] || environment "systemd is not PID 1"
need systemctl
need loginctl
need apt-get
[ -c /dev/uinput ] || environment "/dev/uinput is absent (modprobe uinput)"
[ -f "${SRC}/static/ergopti_plus/linux/install.sh" ] || environment "no checkout subset at ${SRC}"

section "Host"
say "  ..   kernel $(uname -r); systemd $(systemctl --version | head -1 | cut -d' ' -f2)"
export DEBIAN_FRONTEND=noninteractive
# Test tooling only: the product's dependencies are install.sh's job.
apt-get install -y -qq --no-install-recommends sudo xvfb xauth dbus-user-session procps >/dev/null \
	|| environment "could not install the test tooling"

id "${PHYS_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${PHYS_USER}"
echo "${PHYS_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${PHYS_USER}"
chmod 0440 "/etc/sudoers.d/${PHYS_USER}"
PHYS_UID="$(id -u "${PHYS_USER}")"
PHYS_HOME="$(sed -n "s/^${PHYS_USER}:[^:]*:[^:]*:[^:]*:[^:]*:\([^:]*\):.*/\1/p" /etc/passwd)"
RUNTIME_DIR="/run/user/${PHYS_UID}"
loginctl enable-linger "${PHYS_USER}"

await() { # seconds command...
	local seconds="$1"; shift
	local i
	for ((i = 0; i < seconds * 4; i++)); do "$@" && return 0; sleep 0.25; done
	return 1
}
await 60 test -S "${RUNTIME_DIR}/bus" || environment "the user manager never opened its bus"

as_user() {
	sudo -u "${PHYS_USER}" env HOME="${PHYS_HOME}" XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus" DISPLAY="${DISPLAY_NUMBER}" \
		https_proxy="${https_proxy:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" bash -c "cd ~ && $1"
}
user_systemctl() { as_user "systemctl --user $*"; }
main_pid() { user_systemctl "show -p MainPID --value ergopti-hotstrings.service" 2>/dev/null; }
alive() { [ -n "$1" ] && [ "$1" != 0 ] && [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
in_unit() { grep -q '/ergopti-hotstrings.service$' "/proc/$1/cgroup" 2>/dev/null; }

section "Installer"
# A first install: nothing of an earlier run of this script survives. A
# reinstall over an older tree keeps the files it no longer ships, which is a
# separate installer defect (TODO.md), not this scenario.
user_systemctl "stop ergopti-hotstrings.service" 2>/dev/null || true
rm -rf "${PHYS_HOME}/.local/lib/ergopti" "${PHYS_HOME}/.local/lib/ergopti.old" "${PHYS_HOME}/.local/bin/ergopti-hotstrings" \
	"${PHYS_HOME}/.config/systemd/user/ergopti-hotstrings.service.d"
rm -rf "${PHYS_HOME}/ergopti"
mkdir -p "${PHYS_HOME}/ergopti/static/layouts" "${PHYS_HOME}/ergopti/tools/build"
cp -r "${SRC}/static/ergopti_plus" "${PHYS_HOME}/ergopti/static/"
cp -r "${SRC}/static/layouts/registry" "${PHYS_HOME}/ergopti/static/layouts/"
cp "${SRC}/package.json" "${PHYS_HOME}/ergopti/"
cp "${SRC}/tools/build/build-linux-native-output.sh" "${PHYS_HOME}/ergopti/tools/build/"
chown -R "${PHYS_USER}" "${PHYS_HOME}/ergopti"
if as_user "bash ~/ergopti/static/ergopti_plus/linux/install.sh" > "${RECEIPTS}/install.log" 2>&1; then
	ok "install.sh exited 0 with a reachable user manager"
else
	fail "install.sh failed"
	tail -40 "${RECEIPTS}/install.log"
fi
check "the installer enabled the user unit" test "$(user_systemctl 'is-enabled ergopti-hotstrings.service')" = enabled
LIB_ROOT="${PHYS_HOME}/.local/lib/ergopti"
check "the standalone tree is installed at ~/.local/lib/ergopti" test -f "${LIB_ROOT}/linux/ergopti_hotstrings.lua"

section "Session"
# The groups install.sh granted apply to processes of the next login only.
systemctl restart "user@${PHYS_UID}.service"
await 60 test -S "${RUNTIME_DIR}/bus" || environment "the user manager did not come back"
as_user "Xvfb ${DISPLAY_NUMBER} -nolisten tcp >/dev/null 2>&1 &"
await 20 test -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" || environment "Xvfb did not start"
# What a desktop login does: the manager's units see the session display.
user_systemctl "set-environment DISPLAY=${DISPLAY_NUMBER}"
FIFO="$(mktemp -u /tmp/ergopti-phys-ctl.XXXXXX)"
mkfifo -m 600 "${FIFO}"
NODE_FILE="$(mktemp /tmp/ergopti-phys-node.XXXXXX)"
PROBES="$(mktemp -d /tmp/ergopti-phys-probes.XXXXXX)"
DRIVER="${SRC}/static/ergopti_plus/linux"
(cd "${DRIVER}" && LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;' \
	exec luajit tests/hardware/layouts/phys_keyboard.lua "${NODE_FILE}" "${FIFO}" "${PROBES}") \
	> "${RECEIPTS}/keyboard.log" 2>&1 &
KEYBOARD_PID=$!
await 20 test -s "${NODE_FILE}" || environment "the test keyboard never appeared"
NODE="$(cat "${NODE_FILE}")"
say "  ..   test keyboard ${NODE}"
check "the user can read the keyboard (input group of the new login)" as_user "test -r ${NODE}"
DROPIN="${PHYS_HOME}/.config/systemd/user/ergopti-hotstrings.service.d"
mkdir -p "${DROPIN}"
printf '[Service]\nExecStart=\nExecStart=%%h/.local/bin/ergopti-hotstrings --tray --verbose --device %s\n' "${NODE}" \
	> "${DROPIN}/phys-device.conf"
chown -R "${PHYS_USER}" "${PHYS_HOME}/.config/systemd"
user_systemctl "daemon-reload"
user_systemctl "restart ergopti-hotstrings.service"

probe() { # label count interval_ms
	rm -f "${PROBES}/$1.done" "${PROBES}/$1.txt"
	printf 'probe %s %s %s\n' "$1" "$2" "$3" > "${FIFO}"
}
probe_wait() { await 600 test -f "${PROBES}/$1.done"; cat "${PROBES}/$1.txt"; }
probe_holds() { # label: every key echoed, p90 under the ceiling
	local line p90 missing
	line="$(cat "${PROBES}/$1.txt")"
	missing="$(sed -n 's/.*missing=\([0-9]*\).*/\1/p' <<<"${line}")"
	p90="$(sed -n 's/.*p90_ms=\([0-9.]*\).*/\1/p' <<<"${line}")"
	[ "${missing}" = 0 ] && [ -n "${p90}" ] && [ "${p90%.*}" -lt "${LATENCY_LIMIT_MS}" ]
}
# Ready: keys typed on the source come back on the daemon's output.
ready() {
	probe ready 3 50
	probe_wait ready >/dev/null
	probe_holds ready
}
await 240 ready
check "the unit's daemon grabs the keyboard and re-emits keys" probe_holds ready
FIRST="$(main_pid)"
check "the daemon runs inside the unit (MainPID ${FIRST})" in_unit "${FIRST}"
probe baseline 40 20
say "  ..   baseline: $(probe_wait baseline)"
check "baseline input latency" probe_holds baseline

request_reload() { # receipt file
	as_user "sh ${SRC}/tools/control/request_driver_reload.sh ${RELOAD_TIMEOUT_SECONDS}" > "$1" 2>&1
}
json_field() { sed -n "s/.*\"$2\":\([0-9]*\).*/\1/p" "$1" | head -1; }
json_state() { sed -n 's/.*"state":"\([a-z_]*\)".*/\1/p' "$1" | head -1; }

section "systemd restart"
request_reload "${RECEIPTS}/systemd-reload.json"
RELOAD_STATUS=$?
SECOND="$(main_pid)"
check "the tool reads completed (exit ${RELOAD_STATUS}, state $(json_state "${RECEIPTS}/systemd-reload.json"))" \
	test "${RELOAD_STATUS}" = 0 -a "$(json_state "${RECEIPTS}/systemd-reload.json")" = completed
check "the user manager started a new MainPID: ${FIRST} -> ${SECOND}" test -n "${SECOND}" -a "${SECOND}" != 0 -a "${SECOND}" != "${FIRST}"
check "the successor completed the request itself" test "$(json_field "${RECEIPTS}/systemd-reload.json" successor_pid)" = "${SECOND}"
check "the replaced daemon is gone" bash -c "$(declare -f alive); ! alive ${FIRST}"
check "the successor runs inside the unit" in_unit "${SECOND}"
check "the restart went through the user manager (journal names the stop and start)" \
	bash -c "journalctl _UID=${PHYS_UID} -u 'user@${PHYS_UID}.service' --since '-10min' --no-pager -o cat | grep -q 'Stopped ergopti-hotstrings.service'"
await 120 ready
probe after_systemd 40 20
say "  ..   after the systemd restart: $(probe_wait after_systemd)"
check "keys flow through the successor" probe_holds after_systemd

section "Owned smoke deadline"
INSTALLED_LUA_PATH="${LIB_ROOT}/linux/?.lua;${LIB_ROOT}/linux/?/init.lua;${LIB_ROOT}/_shared/?.lua;${LIB_ROOT}/_shared/?/init.lua;;"
INSTALLED_LUA_CPATH="${LIB_ROOT}/linux/native_modules/?.so;;"
cp "${DRIVER}/tests/hardware/layouts/phys_smoke_deadline.lua" /tmp/ergopti-phys-smoke.lua
chmod 644 /tmp/ergopti-phys-smoke.lua
probe during_smoke 300 20
as_user "LUA_PATH='${INSTALLED_LUA_PATH}' LUA_CPATH='${INSTALLED_LUA_CPATH}' \
	luajit /tmp/ergopti-phys-smoke.lua '${LIB_ROOT}' ~/ergopti/static/ergopti_plus/linux/install.sh \
	\"\$(mktemp -d)/smoke\"" > "${RECEIPTS}/smoke-deadline.log" 2>&1
SMOKE_STATUS=$?
sed 's/^/     /' "${RECEIPTS}/smoke-deadline.log" | tee -a "${SUMMARY}" >/dev/null
check "the installed async installer's checks hold (exit ${SMOKE_STATUS})" test "${SMOKE_STATUS}" = 0
say "  ..   keys during the install: $(probe_wait during_smoke)"
check "the daemon kept re-emitting keys while the smoke hung" probe_holds during_smoke
check "the unit's daemon was not disturbed by the rolled-back install" test "$(main_pid)" = "${SECOND}"
user_systemctl "restart ergopti-hotstrings.service"
await 120 ready
check "the unit restarts on the restored tree and re-emits keys" probe_holds ready

section "Relay restart"
user_systemctl "stop ergopti-hotstrings.service"
as_user "setsid ~/.local/bin/ergopti-hotstrings --tray --verbose --device ${NODE} > /tmp/ergopti-phys-relay.log 2>&1 < /dev/null &"
await 120 ready
# The user's daemon process: its command line names the driver entry point.
daemon_pid() {
	local dir
	for dir in /proc/[0-9]*; do
		[ "$(stat -c %u "${dir}" 2>/dev/null)" = "${PHYS_UID}" ] || continue
		tr '\0' ' ' < "${dir}/cmdline" 2>/dev/null | grep -q 'ergopti_hotstrings\.lua' && { echo "${dir#/proc/}"; return 0; }
	done
	return 1
}
RELAY_FIRST="$(daemon_pid)"
check "the daemon started outside the unit (pid ${RELAY_FIRST})" bash -c "[ -n '${RELAY_FIRST}' ] && ! grep -q 'ergopti-hotstrings.service' /proc/${RELAY_FIRST}/cgroup"
request_reload "${RECEIPTS}/relay-reload.json"
RELAY_STATUS=$?
RELAY_SECOND="$(json_field "${RECEIPTS}/relay-reload.json" successor_pid)"
check "the tool reads completed (exit ${RELAY_STATUS}, state $(json_state "${RECEIPTS}/relay-reload.json"))" \
	test "${RELAY_STATUS}" = 0 -a "$(json_state "${RECEIPTS}/relay-reload.json")" = completed
check "the relay started a new process: ${RELAY_FIRST} -> ${RELAY_SECOND}" test -n "${RELAY_SECOND}" -a "${RELAY_SECOND}" != "${RELAY_FIRST}"
check "the first process is gone" bash -c "$(declare -f alive); ! alive ${RELAY_FIRST}"
check "the successor is alive and outside the unit" bash -c "$(declare -f alive); alive ${RELAY_SECOND} && ! grep -q 'ergopti-hotstrings.service' /proc/${RELAY_SECOND}/cgroup"
check "the unit stayed inactive (no second daemon)" test "$(user_systemctl 'is-active ergopti-hotstrings.service')" != active
await 120 ready
probe after_relay 40 20
say "  ..   after the relay restart: $(probe_wait after_relay)"
check "keys flow through the relay's successor" probe_holds after_relay
kill "${RELAY_SECOND}" 2>/dev/null
await 30 bash -c "! kill -0 ${RELAY_SECOND} 2>/dev/null"

printf 'quit\n' > "${FIFO}"
wait "${KEYBOARD_PID}" 2>/dev/null
rm -f "${FIFO}" "${NODE_FILE}"
cp "${PROBES}"/*.txt "${RECEIPTS}/" 2>/dev/null
rm -rf "${PROBES}"
say ""
say "${CHECKS} checks, ${FAILURES} failures"
[ "${FAILURES}" -eq 0 ]
