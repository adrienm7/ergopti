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
DRIVER="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
REPO="$(cd "${DRIVER}/../../.." && pwd -P)" || exit 2
for tool in luajit tar curl sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
luajit -e 'require("luv")' 2>/dev/null || { echo "ENVIRONMENT: lua-luv is missing" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/home/.cache" "${WORK}/unpacked"

# An old release: the updater compares versions, so any published one is newer.
ERGOPTI_BUILD_VERSION=0.0.0-dev.1 bash "${REPO}/tools/build/build-linux-driver.sh" --skip-smoke \
	> "${WORK}/build.log" 2>&1 || { tail -20 "${WORK}/build.log"; echo "FAIL the build failed"; exit 1; }
tar -czf "${WORK}/old.tar.gz" -C "${REPO}/build/linux" linux _shared bin install.sh
tar -xzf "${WORK}/old.tar.gz" -C "${WORK}/unpacked"

export HOME="${WORK}/home"
export XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share" XDG_CACHE_HOME="${HOME}/.cache"
( cd "${WORK}/unpacked" && bash install.sh --no-deps --no-service ) > "${WORK}/install.log" 2>&1 \
	|| { tail -20 "${WORK}/install.log"; echo "FAIL install.sh failed"; exit 1; }

# The installed tree, as its launcher loads it; the restart relay is this
# checkout's, as it is the running daemon's own code that restarts it.
LIB="${HOME}/.local/lib/ergopti"
export LUA_PATH="${LIB}/linux/?.lua;${LIB}/linux/?/init.lua;${LIB}/_shared/lua/?.lua;${LIB}/_shared/lua/?/init.lua;;"
luajit "${DRIVER}/tests/hardware/run_updater_live.lua" "${DRIVER}" "${HOME}"
STATUS=$?
[ "${STATUS}" -eq 0 ] || exit 1

# The restarted daemon: started by the relay once the updater's process exited,
# from the installed launcher, it must report the version just installed.
NEW="$(sed -n 's/^version=//p' "${LIB}/_shared/build_stamp.txt")"
for _ in $(seq 1 40); do
	grep -qs "daemon starting (version ${NEW}," "${XDG_DATA_HOME}/ergopti/logs/"*.log && break
	sleep 0.5
done
pkill -f "${LIB}/linux/ergopti_hotstrings.lua" 2>/dev/null
if grep -qs "daemon starting (version ${NEW}," "${XDG_DATA_HOME}/ergopti/logs/"*.log; then
	echo "  ok   the daemon restarted on ${NEW}"
	exit 0
fi
echo "  FAIL the daemon did not restart on ${NEW}"
tail -20 "${XDG_DATA_HOME}/ergopti/logs/"*.log 2>/dev/null
exit 1
