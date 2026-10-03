#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_updater_live.sh
#
# The updater a user runs, run: this tree is built as an old release
# (0.0.0-dev.1), installed with its own install.sh into a throwaway home, and
# its updater — the one the tray drives — is left to find the newest published
# release on GitHub, download it, verify its SHA-256, install it with a
# rollback backup, and restart the daemon on it. run_updater_live.lua checks
# every step and that the daemon it restarts reports the new version.
#
# Needs network access to GitHub, luajit, lua-luv, tar, sha256sum and curl.
# Run from anywhere. Exit 0 = updated and restarted; 1 = a failure;
# 2 = no environment.

set -u
WORK=""
PHASE=environment
CAUSE_STATUS=0
EVIDENCE_DIR="${ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR:-}"

# Preserve the owner verdict even when an optional diagnostic copy or cleanup
# fails. Only this runner's logs leave its disposable installation directory.
finish() {
	local terminal=$?
	trap - EXIT
	if [ -n "${EVIDENCE_DIR}" ]; then
		if mkdir -p "${EVIDENCE_DIR}"; then
			printf 'phase=%s\nexit_status=%s\ncause_exit_status=%s\nsha=%s\n' \
				"${PHASE}" "${terminal}" "${CAUSE_STATUS}" "${GITHUB_SHA:-}" \
				> "${EVIDENCE_DIR}/result.txt" || echo "Updater verdict evidence could not be written." >&2
			if [ -n "${WORK}" ]; then
				for log in build install updater.stdout updater.stderr; do
					if [ -f "${WORK}/${log}.log" ]; then
						cp "${WORK}/${log}.log" "${EVIDENCE_DIR}/${log}.log" \
							|| echo "Updater log evidence could not be copied." >&2
					fi
				done
			fi
		else
			echo "Updater evidence directory could not be created." >&2
		fi
	fi
	if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${terminal}" -ne 0 ]; then
		printf '::error title=Linux updater live::phase=%s; exit=%s; cause exit=%s\n' \
			"${PHASE}" "${terminal}" "${CAUSE_STATUS}" >&2
	fi
	if [ -n "${WORK}" ]; then rm -rf "${WORK}"; fi
	exit "${terminal}"
}
trap finish EXIT
DRIVER="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
REPO="$(cd "${DRIVER}/../../.." && pwd -P)" || exit 2
for tool in luajit tar curl sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || { CAUSE_STATUS=$?; echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
luajit -e 'require("luv")' 2>/dev/null || { CAUSE_STATUS=$?; echo "ENVIRONMENT: lua-luv is missing" >&2; exit 2; }

WORK="$(mktemp -d)"
mkdir -p "${WORK}/home/.cache" "${WORK}/unpacked"

# An old release: the updater compares versions, so any published one is newer.
PHASE=build
ERGOPTI_BUILD_VERSION=0.0.0-dev.1 bash "${REPO}/tools/build/build-linux-driver.sh" --skip-smoke \
	> "${WORK}/build.log" 2>&1 || { CAUSE_STATUS=$?; tail -20 "${WORK}/build.log"; echo "FAIL the build failed"; exit 1; }
tar -czf "${WORK}/old.tar.gz" -C "${REPO}/build/linux" linux _shared bin install.sh
tar -xzf "${WORK}/old.tar.gz" -C "${WORK}/unpacked"

export HOME="${WORK}/home"
export XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share" XDG_CACHE_HOME="${HOME}/.cache"
export XDG_STATE_HOME="${HOME}/.local/state"
# Where the daemon writes its logs: state, not data (infra/config_paths.lua).
# The check read the data folder, which only builds before v0.0.0-dev.140 used.
LOGS="${XDG_STATE_HOME}/ergopti_plus/logs"
PHASE=install
( cd "${WORK}/unpacked" && bash install.sh --no-deps --no-service ) > "${WORK}/install.log" 2>&1 \
	|| { CAUSE_STATUS=$?; tail -20 "${WORK}/install.log"; echo "FAIL install.sh failed"; exit 1; }

# The installed tree, as its launcher loads it; the restart relay is this
# checkout's, as it is the running daemon's own code that restarts it.
LIB="${HOME}/.local/lib/ergopti"
export LUA_PATH="${LIB}/linux/?.lua;${LIB}/linux/?/init.lua;${LIB}/_shared/lua/?.lua;${LIB}/_shared/lua/?/init.lua;;"
PHASE=updater
if [ -n "${EVIDENCE_DIR}" ]; then
	mkdir -p "${EVIDENCE_DIR}" || echo "Updater evidence directory could not be created." >&2
fi
# Keep both streams visible and wait for their copies before EXIT publishes
# evidence. Fixed descriptors also work with macOS's Bash 3.2 test runner.
exec 3> >(tee "${WORK}/updater.stdout.log")
STDOUT_PID=$!
exec 4> >(tee "${WORK}/updater.stderr.log" >&2)
STDERR_PID=$!
luajit "${DRIVER}/tests/hardware/run_updater_live.lua" "${DRIVER}" "${HOME}" >&3 2>&4 3>&- 4>&-
STATUS=$?
CAUSE_STATUS=${STATUS}
exec 3>&- 4>&-
wait "${STDOUT_PID}" || echo "Updater stdout evidence could not be copied." >&2
wait "${STDERR_PID}" || echo "Updater stderr evidence could not be copied." >&2
[ "${STATUS}" -eq 0 ] || exit 1

# The restarted daemon: started by the relay once the updater's process exited,
# from the installed launcher, it must report the version just installed.
PHASE=restart
NEW="$(sed -n 's/^version=//p' "${LIB}/_shared/build_stamp.txt")"
for _ in $(seq 1 40); do
	grep -qs "daemon starting (version ${NEW}," "${LOGS}/"*.log && break
	sleep 0.5
done
pkill -f "${LIB}/linux/ergopti_hotstrings.lua" 2>/dev/null
if grep -qs "daemon starting (version ${NEW}," "${LOGS}/"*.log; then
	PHASE=complete
	echo "  ok   the daemon restarted on ${NEW}"
	exit 0
fi
CAUSE_STATUS=1
echo "  FAIL the daemon did not restart on ${NEW}"
tail -20 "${LOGS}/"*.log 2>/dev/null
exit 1
