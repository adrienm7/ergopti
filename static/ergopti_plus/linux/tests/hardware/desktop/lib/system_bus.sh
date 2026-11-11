#!/usr/bin/env bash
# tests/hardware/desktop/lib/system_bus.sh
#
# ==============================================================================
# MODULE: System Bus And Logind For The Container Proofs
# DESCRIPTION:
# Sourced by the tests/hardware/desktop launchers whose session needs logind:
# GNOME Shell 46 asks org.freedesktop.login1 for its background and aborts
# without it, and the keep-awake proof reads logind's inhibitor list. A
# container has neither until a proof starts them. A socket file alone is no
# live bus: a killed daemon leaves /run/dbus/system_bus_socket behind, so the
# bus is asked, and a stale socket is replaced only when nothing answers.
# system_logind_ensure returns 2 when either service cannot start and leaves
# the pid of a logind it started in SYSTEM_LOGIND_PID (empty when one already
# answered), for the caller to stop.
# ==============================================================================

SYSTEM_LOGIND_PID=""

# Starts the system bus and logind when they do not answer.
system_logind_ensure() {
	local logind=/usr/lib/systemd/systemd-logind
	command -v busctl >/dev/null 2>&1 || { echo "ENVIRONMENT: busctl is missing" >&2; return 2; }
	command -v dbus-daemon >/dev/null 2>&1 || { echo "ENVIRONMENT: dbus-daemon is missing" >&2; return 2; }
	[ -x "${logind}" ] || { echo "ENVIRONMENT: ${logind} is missing" >&2; return 2; }
	if ! busctl --system status >/dev/null 2>&1; then
		rm -f /run/dbus/system_bus_socket /run/dbus/pid
		mkdir -p /run/dbus
		dbus-daemon --system --fork || { echo "ENVIRONMENT: the system bus did not start" >&2; return 2; }
	fi
	busctl --system status org.freedesktop.login1 >/dev/null 2>&1 && return 0
	"${logind}" >/dev/null 2>&1 &
	SYSTEM_LOGIND_PID=$!
	for _ in $(seq 1 50); do
		busctl --system status org.freedesktop.login1 >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	echo "ENVIRONMENT: logind did not start" >&2
	return 2
}
