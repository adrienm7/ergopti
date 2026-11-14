#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_atspi_focus.sh
#
# The secure-field probe against a real accessibility bus, a real window
# manager and real GTK applications — the only setting in which the defect it
# pins exists. Every GTK application keeps FOCUSED on the field it last
# focused, so with two windows open the desktop holds two focused fields and
# only the window manager's ACTIVE frame says which one the user is in. The
# probe used to search the whole desktop, found two, called it ambiguous, and
# the daemon — which fails closed — blocked every expansion as soon as a second
# application was open.
#
# Needs: Xvfb, dbus-launch, at-spi2-core, openbox, python3-gi with Gtk 3.
# Run from the driver root. Exit 0 = every check held; 1 = a check failed;
# 2 = the environment cannot host the test.

set -u
cd "$(dirname "$0")/../.." || exit 2
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
FIXTURE="tests/hardware/atspi_fixture_app.py"
BUS_LAUNCHER=""
for candidate in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
	[ -x "${candidate}" ] && BUS_LAUNCHER="${candidate}" && break
done
for tool in Xvfb dbus-launch openbox python3 luajit; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
[ -n "${BUS_LAUNCHER}" ] || { echo "ENVIRONMENT: at-spi-bus-launcher is missing" >&2; exit 2; }

Xvfb :57 -screen 0 1024x768x24 >/dev/null 2>&1 &
PIDS="$!"
export DISPLAY=:57
eval "$(dbus-launch --sh-syntax)"
PIDS="${PIDS} ${DBUS_SESSION_BUS_PID}"
"${BUS_LAUNCHER}" --launch-immediately >/dev/null 2>&1 &
PIDS="${PIDS} $!"
# A GTK application asks for the accessibility bus once, at start: one started
# before the launcher serves it never joins and reads inconclusive. A fixed
# one-second sleep lost that race on a slow runner.
READY_TIMEOUT_SECONDS=20
python3 tests/hardware/wait_a11y_bus.py "${READY_TIMEOUT_SECONDS}" || { kill ${PIDS} 2>/dev/null; exit 2; }
openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"
WORK="$(mktemp -d)"

FAILURES=0
probe() {
	luajit -e "local m=require('adapters.atspi_focus'); local s,ok=m._get_native_snapshot(); print(ok and ('role='..s.role) or 'inconclusive')" 2>"${WORK}/probe.err" | tail -1
}
check() {
	local what="$1" expected="$2" got
	got="$(probe)"
	if [ "${got}" = "${expected}" ]; then
		echo "  ok   ${what} (${got})"
	else
		echo "  FAIL ${what}: expected ${expected}, got ${got}"
		sed 's/^/       probe: /' "${WORK}/probe.err"
		FAILURES=$((FAILURES + 1))
	fi
}
# Opens one fixture window and waits until the window manager made it active
# with its field focused, the state a probe reads; a fixed sleep raced it.
open_fixture() {
	local name="$1"
	shift
	python3 "${FIXTURE}" "${name}" "$@" --ready-file "${WORK}/${name}.ready" >/dev/null 2>&1 &
	PIDS="${PIDS} $!"
	local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
	until [ -e "${WORK}/${name}.ready" ]; do
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			echo "  FAIL the ${name} window was not active and focused within ${READY_TIMEOUT_SECONDS} s"
			FAILURES=$((FAILURES + 1))
			return 1
		fi
		sleep 0.05
	done
}

echo "=== secure-field probe on a real accessibility bus ==="
open_fixture editor && check "one application with a focused text field" "role=61"

open_fixture second && check "a second application opened on top — still one answer, the active window's" "role=61"

open_fixture login password && check "a password field in the active window is recognised as one" "role=40"

# shellcheck disable=SC2086
kill ${PIDS} 2>/dev/null
rm -rf "${WORK}"
echo "=== ${FAILURES} failure(s) ==="
[ "${FAILURES}" -eq 0 ]
