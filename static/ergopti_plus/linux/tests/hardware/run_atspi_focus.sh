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
	luajit -e "local m=require('platform.focus.atspi_focus'); local s,ok=m._get_native_snapshot(); print(ok and ('role='..s.role) or 'inconclusive')" 2>"${WORK}/probe.err" | tail -1
}
# A window's own is-active and focus signals can run before its accessible
# frame and field publish ACTIVE and FOCUSED on the bus, so a probe right after the
# ready file can still read two ACTIVE frames or no focused field (CI run
# 43951206595, third probe). Only "inconclusive" is read again, until the
# ready timeout; a wrong role fails at once.
check() {
	local what="$1" expected="$2" got
	local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
	got="$(probe)"
	while [ "${got}" = inconclusive ] && [ "${SECONDS}" -lt "${deadline}" ]; do
		sleep 0.1
		got="$(probe)"
	done
	if [ "${got}" = "${expected}" ]; then
		echo "  ok   ${what} (${got})"
	else
		echo "  FAIL ${what}: expected ${expected}, got ${got}"
		sed 's/^/       probe: /' "${WORK}/probe.err"
		FAILURES=$((FAILURES + 1))
	fi
}
# Opens one fixture window and waits for the state a probe reads: the window
# manager made it active with its field focused, AND every window opened before
# it has resigned. Each fixture learns it lost activation in its own process,
# after the new window's ready file can exist; until then two frames report
# ACTIVE and the probe answers inconclusive (CI run 43679709990, third probe).
#
# Every fixture outlives the whole run: three openings and their resign waits
# can take 2 × READY_TIMEOUT_SECONDS each on a slow runner, and a window that
# quits mid-run changes the desktop under test (the default lifetime, 30 s,
# was shorter than a slow run).
FIXTURE_LIFETIME_SECONDS=$((READY_TIMEOUT_SECONDS * 8))
OPENED=""
# Says what each window opened so far reports, and whether it still runs.
report_windows() {
	local opened
	for opened in ${OPENED} "$1"; do
		local pid
		pid="$(cat "${WORK}/${opened}.pid" 2>/dev/null)"
		echo "       ${opened}: $(cat "${WORK}/${opened}.state" 2>/dev/null || echo 'no state'), process $( [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && echo running || echo gone)"
	done
}
open_fixture() {
	local name="$1"
	shift
	python3 "${FIXTURE}" "${name}" "$@" --ready-file "${WORK}/${name}.ready" \
		--state-file "${WORK}/${name}.state" --lifetime-seconds "${FIXTURE_LIFETIME_SECONDS}" >/dev/null 2>&1 &
	PIDS="${PIDS} $!"
	echo "$!" >"${WORK}/${name}.pid"
	local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
	until [ -e "${WORK}/${name}.ready" ]; do
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			echo "  FAIL the ${name} window was not active and focused within ${READY_TIMEOUT_SECONDS} s"
			report_windows "${name}"
			FAILURES=$((FAILURES + 1))
			return 1
		fi
		sleep 0.05
	done
	local earlier
	for earlier in ${OPENED}; do
		until [ "$(cat "${WORK}/${earlier}.state" 2>/dev/null)" = inactive ]; do
			if [ "${SECONDS}" -ge "${deadline}" ]; then
				echo "  FAIL the ${earlier} window still reported itself active ${READY_TIMEOUT_SECONDS} s after ${name} opened"
				report_windows "${name}"
				FAILURES=$((FAILURES + 1))
				return 1
			fi
			sleep 0.05
		done
	done
	OPENED="${OPENED} ${name}"
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
