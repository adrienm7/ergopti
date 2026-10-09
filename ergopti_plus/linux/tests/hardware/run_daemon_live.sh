#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_daemon_live.sh
#
# A desktop for run_daemon_live.lua: an X server, a session bus, the
# accessibility bus, a window manager, a focused GTK text field (the fail-closed
# privacy gate lets nothing expand without one), sni_host.py standing in for
# the panel, and fake_llm_server.py standing in for a hosted AI API. Then the
# real daemon, a real trigger, a real prediction, and the tray it shows.
#
# Needs root (uinput and the grab), Xvfb, dbus-launch, at-spi2-core, openbox,
# xkbcomp, python3-gi with Gtk 3. Run from anywhere.
# Exit 0 = expansion and tray both verified; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../.." || exit 2
export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
BUS_LAUNCHER=""
for candidate in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
	[ -x "${candidate}" ] && BUS_LAUNCHER="${candidate}" && break
done
for tool in Xvfb dbus-launch openbox python3 luajit xkbcomp; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
[ -n "${BUS_LAUNCHER}" ] || { echo "ENVIRONMENT: at-spi-bus-launcher is missing" >&2; exit 2; }

Xvfb :58 -screen 0 1024x768x24 >/dev/null 2>&1 &
PIDS="$!"
export DISPLAY=:58
eval "$(dbus-launch --sh-syntax)"
PIDS="${PIDS} ${DBUS_SESSION_BUS_PID}"
"${BUS_LAUNCHER}" --launch-immediately >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
openbox >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 1
python3 tests/hardware/atspi_fixture_app.py editor >/dev/null 2>&1 &
PIDS="${PIDS} $!"
sleep 2

# Native virtual-keyboard custody runs before the timed tray/daemon host. Its
# two explicit sources and output use real production FFI ports, then retire.
luajit tests/hardware/run_modifier_custody.lua
CUSTODY=$?
# The input-owner prerequisite must cross real evdev/uinput descriptors too.
# The existing subreaper retains its exact 40-second deadline and owned cleanup;
# unavailable devices, missing bootstrap admission and any native failure refuse.
if [ "${CUSTODY}" = "0" ]; then
	python3 tests/hardware/run_native_subreaper.py luajit tests/hardware/run_input_owner_real.lua
	CUSTODY=$?
fi
# Saved simultaneous configuration crosses the original Manager and publisher.
# Its distinct kernel supplement retains the existing subreaper deadline.
if [ "${CUSTODY}" = "0" ]; then
	if [ "${GITHUB_ACTIONS:-}" = true ]; then
		mode=full
		if [ -z "${RUNNER_TEMP:-}" ]; then CUSTODY=2; fi
		receipt="${RUNNER_TEMP:-}/stable-linux-simultaneous-native.json"
		if [ "$CUSTODY" = "0" ]; then
			node ../../../tools/ci/dev-release-qualification.cjs --scope linux-simultaneous-native --receipt "$receipt" || CUSTODY=$?
		fi
		if [ "$CUSTODY" = "0" ]; then
			mode="$(node ../../../tools/ci/dev-release-qualification.cjs --scope linux-simultaneous-native --validate-scope-receipt "$receipt")" || CUSTODY=$?
		fi
	else
		mode=full
	fi
	if [ "$CUSTODY" != "0" ]; then
		: # The existing owned-host failure enclosure below performs cleanup.
	elif [ "$mode" = deferred ]; then
		echo '[DEFERRED] linux-simultaneous-native: qualified=false; saved-configuration supplement not executed.'
	elif [ "$mode" = full ]; then
		python3 tests/hardware/run_native_subreaper.py luajit tests/hardware/run_simultaneous_configuration_real.lua
		CUSTODY=$?
	else
		CUSTODY=2
	fi
fi
if [ "${CUSTODY}" != "0" ]; then
	# shellcheck disable=SC2086
	kill ${PIDS} 2>/dev/null
	exit "${CUSTODY}"
fi

# A Cerebras-style API on loopback for the AI phase, answering with ASCII-escaped
# JSON as Python servers do.
LLM_READY="$(mktemp -u)"
export ERGOPTI_LIVE_LLM_PORT=18431
export ERGOPTI_LIVE_LLM_LOG="$(mktemp)"
export ERGOPTI_LIVE_LLM_REPLY=" que tout le monde va bien"
# What a model answers the rewrite prompt, which Super+Space runs in the probe.
export ERGOPTI_LIVE_LLM_REWRITE_REPLY="REWRITE: Ok pour jeudi"
python3 tests/hardware/fake_llm_server.py --port "${ERGOPTI_LIVE_LLM_PORT}" --log "${ERGOPTI_LIVE_LLM_LOG}" \
	--reply "${ERGOPTI_LIVE_LLM_REPLY}" --rewrite-reply "${ERGOPTI_LIVE_LLM_REWRITE_REPLY}" \
	--ready-file "${LLM_READY}" &
PIDS="${PIDS} $!"
for _ in $(seq 1 40); do [ -f "${LLM_READY}" ] && break; sleep 0.25; done
[ -f "${LLM_READY}" ] || { echo "ENVIRONMENT: the fake LLM API never started" >&2; exit 2; }

READY="$(mktemp -u)"
REPORT="$(mktemp)"
python3 tests/hardware/sni_host.py --ready-file "${READY}" --timeout 60 --settle 3 \
	--expect-icon-file --min-labels 5 --forbid-raw-keys --expect-label "Tap-Holds" > "${REPORT}" &
HOST=$!
for _ in $(seq 1 40); do [ -f "${READY}" ] && break; sleep 0.25; done
[ -f "${READY}" ] || { echo "ENVIRONMENT: the StatusNotifier host never started" >&2; exit 2; }

echo "=== the whole daemon, live ==="
luajit tests/hardware/run_daemon_live.lua
TYPED=$?
wait "${HOST}"
TRAY=$?
echo "--- the tray the daemon showed ---"
cat "${REPORT}"
# shellcheck disable=SC2086
kill ${PIDS} 2>/dev/null
[ "${TYPED}" = "2" ] && exit 2
if [ "${TRAY}" != "0" ]; then echo "FAIL the tray did not register as expected"; fi
[ "${TYPED}" = "0" ] && [ "${TRAY}" = "0" ]
