#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_update_restart_watcher.sh
#
# The update restart watcher of modules/updater/restarter.lua, end to end, under
# a REAL systemd user manager and from a terminal (the detached relay). Each
# daemon generation is update_watch_daemon.lua, which calls the real restarter
# and the real infra/updater_boot_ready.lua; the installation trees, the swap
# to <root>.old and the launchers are files on disk, as the installer leaves
# them. Three scenarios per mode:
#   healthy  the new tree's daemon reports ready: the watch log reads
#            "reported a healthy start" and the new tree stays;
#   broken   the new tree's bin/ launcher exits at once: the tree moves to
#            <root>.failed-<pid>, <root>.old is back and the previous daemon
#            runs (the elapsed time is printed);
#   quit     the user quits the UPDATED daemon during the watcher's wait,
#            before its ready report, through the real infra/quit_request.lua
#            handler: the update stays installed and no daemon is started.
#
# Why the Quit is in the updated daemon: once the old daemon asks for the
# restart, a relay restart has already requested its shutdown (a later Quit
# there is refused, an exit owns the process) and under the unit systemd TERMs
# it as soon as the job runs. The watcher's 60 s wait is the new daemon's boot,
# whose tray is up before its ready report: that is where a user can quit.
#
# systemd --user refuses to start unless /run/systemd/system exists (sd_booted).
# This container did not boot systemd, so the script re-executes itself in a
# private mount namespace with a tmpfs there; the user manager itself is the
# distribution's binary, managing a real cgroup for the unit.
#
# Needs root (unshare), systemd, luajit and lua-luv. Run from anywhere.
# Exit 0 = every scenario passed; 1 = a failure; 2 = no environment.

set -u
DRIVER="$(cd "$(dirname "$0")/../../.." && pwd -P)" || exit 2
SELF="${DRIVER}/tests/hardware/desktop/run_update_restart_watcher.sh"
MANAGER=/usr/lib/systemd/systemd
UNIT=ergopti-hotstrings.service
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need unshare
need luajit
need systemctl
need systemd-run
need pkill
need setsid
need awk
[ -x "${MANAGER}" ] || { echo "ENVIRONMENT: ${MANAGER} is missing" >&2; exit 2; }
if [ "${ERGOPTI_WATCH_NAMESPACE:-}" != 1 ]; then
	exec env ERGOPTI_WATCH_NAMESPACE=1 unshare -m bash "${SELF}" "$@"
fi
mount -t tmpfs none /run/systemd || exit 2
mkdir -p /run/systemd/system

S="$(mktemp -d)"
export HOME="${S}/home" XDG_RUNTIME_DIR="${S}/runtime" TMPDIR="${S}/tmp"
# The daemon's configuration folder exists in any install: the relay's cancellation marker lives there.
mkdir -p "${HOME}/.config/ergopti" "${HOME}/.config/systemd/user" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${S}/opt"
chmod 700 "${XDG_RUNTIME_DIR}"
ROOT="${S}/opt/ergopti"
RUNS="${S}/runs"
LOG="${S}/update-watch.log"
STATUS=0
MANAGER_PID=""

cleanup() {
	pkill -f "update_watch_daemon.lua" 2>/dev/null
	[ -n "${MANAGER_PID}" ] && kill "${MANAGER_PID}" 2>/dev/null
	rm -rf "${S}"
}
trap cleanup EXIT

# A tree: kind "daemon" runs a generation, "quit" one quit before ready, "broken" exits at once.
make_tree() {
	local dir="$1" name="$2" kind="$3"
	mkdir -p "${dir}/bin" "${dir}/linux/infra"
	cp "${DRIVER}/infra/updater_boot_ready.lua" "${dir}/linux/infra/"
	echo "${name}" > "${dir}/tree"
	if [ "${kind}" = broken ]; then
		printf '#!/bin/sh\nexit 0\n' > "${dir}/bin/ergopti"
	else
		cat > "${dir}/bin/ergopti" <<-LAUNCHER
			#!/bin/sh
			cd '${DRIVER}' || exit 1
			LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'
			export LUA_PATH
			exec luajit tests/hardware/desktop/update_watch_daemon.lua '${name}' '${ROOT}' '${RUNS}' '${LOG}' '${kind}'
		LAUNCHER
	fi
	chmod +x "${dir}/bin/ergopti"
}

# Waits up to $1 seconds for the condition in $2.
wait_for() {
	local limit="$1" ticks=0
	while ! eval "$2"; do
		ticks=$((ticks + 1))
		[ "${ticks}" -gt $((limit * 10)) ] && return 1
		sleep 0.1
	done
}

pid_of() { awk -v t="$1" '$1 == t { p = $2 } END { print p }' "${RUNS}" 2>/dev/null; }
count_of() { awk -v t="$1" '$1 == t { n++ } END { print n + 0 }' "${RUNS}" 2>/dev/null; }

check() {
	if eval "$2" 2>/dev/null; then echo "  ok   $1"; return; fi
	echo "  FAIL $1"
	sed 's/^/       runs: /' "${RUNS}" 2>/dev/null
	sed 's/^/       log: /' "${LOG}" 2>/dev/null
	sed "s/^/       unit: /" "${S}/unit.log" 2>/dev/null | tail -n 12
	STATUS=1
}

start_old() {
	local mode="$1"
	rm -rf "${S}/opt"/* "${RUNS}" "${LOG}"
	make_tree "${ROOT}" old daemon
	if [ "${mode}" = systemd ]; then
		systemctl --user start "${UNIT}"
	else
		setsid "${ROOT}/bin/ergopti" </dev/null >/dev/null 2>&1 &
	fi
	wait_for 10 '[ -n "$(pid_of old)" ]' || { echo "  FAIL the previous daemon did not start"; STATUS=1; return 1; }
}

# What the installer does: the running tree becomes <root>.old, the new one <root>.
install_new() {
	mv -T "${ROOT}" "${ROOT}.old"
	make_tree "${ROOT}" new "$1"
}

stop_all() {
	[ "$1" = systemd ] && systemctl --user stop "${UNIT}" 2>/dev/null
	pkill -f "update_watch_daemon.lua" 2>/dev/null
	wait_for 5 '! pgrep -f update_watch_daemon.lua >/dev/null' || true
}

scenario() {
	local mode="$1" name="$2"
	echo "${mode} ${name}"
	start_old "${mode}" || return
	local old_pid
	old_pid="$(pid_of old)"
	if [ "${mode}" = systemd ]; then
		check "the daemon runs inside the unit's cgroup" "grep -q '/${UNIT}\$' /proc/${old_pid}/cgroup"
	fi
	case "${name}" in
	healthy)
		install_new daemon
		kill -USR1 "${old_pid}"
		check "the restarter took the ${mode} route" "wait_for 10 'grep -qx \"restart ${mode}\" \"${RUNS}\"'"
		check "the new daemon started" "wait_for 20 '[ -n \"\$(pid_of new)\" ]'"
		check "the watch log reads « reported a healthy start »" "wait_for 20 'grep -q \"reported a healthy start\" \"${LOG}\"'"
		check "the new tree stays installed" "[ \"\$(cat \"${ROOT}/tree\")\" = new ]"
		check "no tree was moved aside" "! ls -d \"${ROOT}\".failed-* >/dev/null 2>&1"
		;;
	broken)
		install_new broken
		local started=${SECONDS}
		kill -USR1 "${old_pid}"
		check "the restarter took the ${mode} route" "wait_for 10 'grep -qx \"restart ${mode}\" \"${RUNS}\"'"
		check "the new tree moved to <root>.failed-<pid>" "wait_for 75 'ls -d \"${ROOT}\".failed-* >/dev/null 2>&1'"
		local failed
		failed="$(basename "$(ls -d "${ROOT}".failed-* 2>/dev/null | head -n 1)")"
		check "its name ends in the watcher's pid (${failed})" "[[ '${failed}' =~ \\.failed-[0-9]+\$ ]]"
		echo "  info rollback after $((SECONDS - started)) s"
		# The watcher waits 600 ticks of `sleep 0.1` (60 s plus each tick's fork), then stops
		# the daemon (up to 5 s in relay mode) and moves the trees: allow 4 s past the wait.
		check "the rollback came within the 60 s boot-ready wait plus the watcher's own steps" "[ $((SECONDS - started)) -le 64 ]"
		check "<root>.old is back at <root>" "[ \"\$(cat \"${ROOT}/tree\")\" = old ] && [ ! -e \"${ROOT}.old\" ]"
		check "the previous daemon runs again" "wait_for 20 '[ \"\$(count_of old)\" = 2 ] && kill -0 \"\$(pid_of old)\"'"
		check "the watch log names the failure" "grep -q 'did not start (no boot report): the previous installation is back' \"${LOG}\""
		;;
	quit)
		install_new quit
		local started=${SECONDS}
		kill -USR1 "${old_pid}"
		check "the restarter took the ${mode} route" "wait_for 10 'grep -qx \"restart ${mode}\" \"${RUNS}\"'"
		check "the updated daemon started under the watcher" "wait_for 20 '[ -n \"\$(pid_of new)\" ]'"
		check "its tray Quit was admitted by infra/quit_request.lua" "wait_for 10 'grep -qx \"quit true\" \"${RUNS}\" && grep -qx \"shutdown tray quit\" \"${RUNS}\"'"
		check "the watch log reads « quit before it reported ready »" "wait_for 20 'grep -q \"quit before it reported ready: the update stays installed\" \"${LOG}\"'"
		echo "  info watcher settled $((SECONDS - started)) s after the restart"
		sleep 3
		check "no daemon was started again" "[ \"\$(count_of old)\" = 1 ] && [ \"\$(count_of new)\" = 1 ] && ! pgrep -f update_watch_daemon.lua >/dev/null"
		check "no update watcher is left" "! pgrep -f 'update-watch' >/dev/null"
		check "the update stays installed" "[ \"\$(cat \"${ROOT}/tree\")\" = new ] && ! ls -d \"${ROOT}\".failed-* >/dev/null 2>&1"
		if [ "${mode}" = systemd ]; then
			check "the unit is stopped" "! systemctl --user is-active --quiet ${UNIT}"
		fi
		;;
	esac
	stop_all "${mode}"
}

# The real unit, with only its launcher path pointed at the scratch installation.
sed -e "s|^ExecStart=.*|ExecStart=${ROOT}/bin/ergopti --tray\nStandardOutput=append:${S}/unit.log\nStandardError=append:${S}/unit.log|" "${DRIVER}/ergopti-hotstrings.service" \
	> "${HOME}/.config/systemd/user/${UNIT}"
"${MANAGER}" --user >"${S}/manager.log" 2>&1 &
MANAGER_PID=$!
wait_for 10 'systemctl --user is-system-running >/dev/null 2>&1 || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ]' \
	|| { echo "ENVIRONMENT: systemd --user did not start" >&2; exit 2; }
echo "systemd --user: $(systemctl --user --version | head -n 1), state $(systemctl --user is-system-running)"

for mode in ${ERGOPTI_WATCH_MODES:-relay systemd}; do
	for name in ${ERGOPTI_WATCH_SCENARIOS:-healthy broken quit}; do scenario "${mode}" "${name}"; done
done
exit "${STATUS}"
