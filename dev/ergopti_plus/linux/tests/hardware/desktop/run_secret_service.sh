#!/usr/bin/env bash
# tests/hardware/desktop/run_secret_service.sh
#
# ==============================================================================
# MODULE: Secret Service Container Proof
# DESCRIPTION:
# Runs run_secret_service.lua in a real X11 session with a real
# gnome-keyring-daemon (Secret Service) whose login keyring has a password and
# is locked before each phase, so GNOME's own gcr-prompter asks to unlock it.
# Needs gnome-keyring, gcr (gcr-prompter), libsecret-tools (secret-tool),
# xdotool, gdbus, LuaJIT with lua-luv.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.
# ==============================================================================

set -u
. "$(dirname "$0")/lib/session.sh"
for tool in gnome-keyring-daemon secret-tool gdbus; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-secrets-XXXXXX")" || exit 2
desktop_session_run x11-openbox 95 bash -c '
	scratch="$1"; password="keyring-proof-password"
	lock() {
		gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets \
			--method org.freedesktop.Secret.Service.Lock "[\"/org/freedesktop/secrets/collection/login\"]" >/dev/null &&
		gdbus introspect --session --dest org.freedesktop.secrets \
			--object-path /org/freedesktop/secrets/collection/login --only-properties | grep -q "Locked = true"
	}
	# Creates the login keyring with this password, then locks it.
	printf "%s" "${password}" | gnome-keyring-daemon --unlock --components=secrets >/dev/null || exit 2
	lock || { echo "ENVIRONMENT: the login keyring cannot be locked" >&2; exit 2; }
	luajit tests/hardware/desktop/run_secret_service.lua add "${scratch}" "${password}" || exit 1
	lock || exit 1
	luajit tests/hardware/desktop/run_secret_service.lua migrate "${scratch}" "${password}"
' secret-service "${scratch}" 2>"${scratch}/stderr"
status=$?
[ "${status}" -eq 0 ] || grep -vE "fd limit|dbus-daemon|SpiRegistry|libEGL|Activat" "${scratch}/stderr" | tail -20 >&2
rm -rf "${scratch}"
exit "${status}"
