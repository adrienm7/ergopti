#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_keyring_receipts.sh
#
# A real secret service for run_keyring_receipts.lua: a private session bus,
# an X server with a window manager (the unlock prompt is a window), and
# gnome-keyring-daemon with a fresh login keyring in a throwaway HOME.
#
# Needs Xvfb, openbox, dbus-run-session, gnome-keyring, libsecret-tools
# (secret-tool), gdbus, xdotool and luajit with luv. Run from anywhere.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
# The inner session re-runs this script after the cd below: name it absolutely,
# since the caller may have given a path relative to another directory.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || exit 2
cd "$(dirname "$0")/../.." || exit 2
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need Xvfb
need openbox
need dbus-run-session
need gnome-keyring-daemon
need secret-tool
need gdbus
need xdotool
need luajit
if [ "${1:-}" != "--inside" ]; then
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	DISPLAY_NUMBER=":$((90 + RANDOM % 9))"
	Xvfb "${DISPLAY_NUMBER}" -nolisten tcp >/dev/null 2>&1 &
	XVFB=$!
	for _ in $(seq 40); do [ -S "/tmp/.X11-unix/X${DISPLAY_NUMBER#:}" ] && break; sleep 0.25; done
	# The bus daemon hands its own environment to every service it activates:
	# with the runner's XDG_RUNTIME_DIR, an activated gnome-keyring looked for
	# the unlocked daemon's control socket under /run/user and never found it.
	mkdir -p "${WORK}/run" && chmod 700 "${WORK}/run"
	DISPLAY="${DISPLAY_NUMBER}" HOME="${WORK}" XDG_RUNTIME_DIR="${WORK}/run" \
		XDG_DATA_HOME="${WORK}/.local/share" dbus-run-session -- bash "$SELF" --inside
	STATUS=$?
	kill "${XVFB}" 2>/dev/null
	exit "${STATUS}"
fi

openbox >/dev/null 2>&1 &
PASSWORD="ergopti-keyring-proof"
# --unlock reads the password up to end of input: no trailing newline.
eval "$(printf '%s' "${PASSWORD}" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
# The unlocked daemon claims the secret service name after it returns. A
# secret-tool call before that made the bus start a second daemon, which
# found the new login keyring unreadable and opened a prompt to create one
# that nobody answers: the step hung until its timeout (run 45247903986).
# NameHasOwner never activates a service, so this wait cannot cause it.
owned=""
for _ in $(seq 40); do
	owned="$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
		--method org.freedesktop.DBus.NameHasOwner org.freedesktop.secrets 2>/dev/null)"
	[ "${owned}" = "(true,)" ] && break
	sleep 0.25
done
if [ "${owned}" != "(true,)" ]; then
	echo "FAIL: the unlocked gnome-keyring-daemon did not claim org.freedesktop.secrets within 10 s" >&2
	exit 1
fi
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
# The proof takes about 15 s. A secret-tool call waiting on a prompt nobody
# answers would otherwise hold the step until its timeout with no message.
timeout -k 5 120 luajit tests/hardware/run_keyring_receipts.lua "${PASSWORD}"
STATUS=$?
if [ "${STATUS}" -eq 124 ] || [ "${STATUS}" -eq 137 ]; then
	echo "FAIL: the keyring proof exceeded 120 s; the check after the last line above waited on an unanswered prompt" >&2
	exit 1
fi
exit "${STATUS}"
