#!/usr/bin/env bash
# tools/dev/linux-field-diagnostics.sh

# ==============================================================================
# MODULE: Linux field report diagnostics
# DESCRIPTION:
# The machine facts tools/dev/collect-linux-field-report.sh adds to each
# report, the Linux counterpart of tools/dev/macos-field-diagnostics.sh: a
# failure the day log cannot explain (keys counted twice, an extra byte, idle
# CPU no timer explains) still has its context. Each function prints raw
# evidence plus machine-readable lines "fact<TAB><type><TAB>key=value..." that
# tools/dev/field-report-facts.py turns into env.json, which the analysis reads.
#
# FEATURES & RATIONALE:
# 1. Instances: every Ergopti daemon and helper with its executable, origin
#    (this clone or an install), start time, parent, cumulative CPU and memory
#    from /proc, at each phase and by the sampler: two daemons at once or a
#    restart is on record.
# 2. Other remappers and text expanders (keyd, kmonad, kanata, interception
#    tools, xremap, evremap, input-remapper, espanso, autokey...) and the input
#    methods; which processes hold each keyboard's evdev node (the ones this
#    user may see); the uinput and evdev access the daemon needs.
# 3. The idle CPU of each daemon process over a quiet window, from /proc.
# 4. The daemon unit's state and restart count, its journal since the run
#    started (scrubbed by the collector like a log) and the app folders.
# 5. Never printed: an address, a serial number or typed text. Every call is
#    bounded by the collector's step runner.
#
# Sourced only; defines functions and runs nothing.
# ==============================================================================

# The quiet window of the idle CPU step; the contract test shortens it.
FIELD_IDLE_SECONDS="${FIELD_IDLE_SECONDS_OVERRIDE:-20}"
# The daemon's entry script, which every driver process runs.
FIELD_DAEMON_SCRIPT="ergopti_hotstrings"
# The remappers, text expanders and input methods, by process name.
FIELD_LINUX_REMAPPERS="keyd kmonad kanata udevmon intercept xremap evremap input-remapper-service input-remapper-reader espanso autokey-gtk autokey-qt xbindkeys sxhkd actkbd keymapperd keymapper interception-k2k"
FIELD_LINUX_INPUT_METHODS="ibus-daemon fcitx5 fcitx"

# Prints a tab-separated fact line. $1 type, then key=value words.
field_fact() {
	local line="fact	$1"
	shift
	while [ "$#" -gt 0 ]; do
		line="${line}	$1"
		shift
	done
	printf '%s\n' "${line}"
}

# Prints the instance facts of one phase (start, before_run, sample, end).
field_linux_instances() {
	local phase="$1" now tck btime pid stat ppid utime stime start cmd exe role name origin rss parent
	now="$(date +%s)"
	tck="$(getconf CLK_TCK 2>/dev/null || echo 100)"
	btime="$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)"
	field_fact sample "phase=${phase}" "t=${now}"
	for pid in $(pgrep -f "ergopti|ydotoold" 2>/dev/null); do
		case "${pid}" in ''|*[!0-9]*) continue ;; esac
		[ "${pid}" = "$$" ] && continue
		[ -r "/proc/${pid}/stat" ] || continue
		cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)"
		case "${cmd}" in
			*"${FIELD_DAEMON_SCRIPT}"*tray*|*"${FIELD_DAEMON_SCRIPT}.lua"*) role=driver; name="${FIELD_DAEMON_SCRIPT}" ;;
			*ydotoold*) role=helper; name=ydotoold ;;
			*/tools/dev/*|*pgrep*) continue ;;
			*ergopti*) role=helper; name="$(sed -n 's/^Name:[[:space:]]*//p' "/proc/${pid}/status" 2>/dev/null)" ;;
			*) continue ;;
		esac
		# Fields after the command name: state ppid ... utime(14) stime(15) ... starttime(22).
		stat="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null)"
		ppid="$(printf '%s\n' "${stat}" | awk '{ print $2 }')"
		utime="$(printf '%s\n' "${stat}" | awk '{ print $12 }')"
		stime="$(printf '%s\n' "${stat}" | awk '{ print $13 }')"
		start="$(printf '%s\n' "${stat}" | awk '{ print $20 }')"
		exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)"
		rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null)"
		parent="$(sed -n 's/^Name:[[:space:]]*//p' "/proc/${ppid:-1}/status" 2>/dev/null)"
		case "${cmd}" in
			*/static/ergopti_plus/linux/*) origin=dev ;;
			*/.local/*|/usr/*|/opt/*) origin=installed ;;
			*) origin=other ;;
		esac
		field_fact instance "phase=${phase}" "t=${now}" "role=${role}" "name=${name}" "pid=${pid}" \
			"ppid=${ppid}" "parent=${parent}" \
			"started=$(awk -v b="${btime:-0}" -v s="${start:-0}" -v t="${tck}" 'BEGIN { printf "%d", b + s / t }')" \
			"cpu_s=$(awk -v u="${utime:-0}" -v s="${stime:-0}" -v t="${tck}" 'BEGIN { printf "%.2f", (u + s) / t }')" \
			"rss_kb=${rss}" "origin=${origin}" "path=${exe}" "version=" "bundle_id=" "team="
	done
}

# Prints the other remappers, text expanders and input methods that run, and
# which processes this user can see holding a keyboard's evdev node.
field_linux_remappers() {
	local running name node holders
	running="$(ps -eo pid=,comm= 2>/dev/null)"
	echo "== Remappers and text expanders"
	for name in ${FIELD_LINUX_REMAPPERS}; do
		if printf '%s\n' "${running}" | awk -v n="${name}" '$2 == n { found = 1 } END { exit !found }'; then
			echo "running: ${name}"
			field_fact remapper "name=${name}" running=yes conflict=yes
		fi
	done
	echo "== Input methods"
	for name in ${FIELD_LINUX_INPUT_METHODS}; do
		if printf '%s\n' "${running}" | awk -v n="${name}" '$2 == n { found = 1 } END { exit !found }'; then
			echo "running: ${name}"
			field_fact remapper "name=${name}" running=yes conflict=no "detail=input method"
		fi
	done
	echo "== Keyboard evdev nodes and the processes of this user holding them"
	for node in /sys/class/input/event*; do
		[ -e "${node}/device/name" ] || continue
		# A keyboard advertises EV_KEY with letter keys; a key bitmap long
		# enough to hold KEY_A..KEY_Z is the cheap test.
		[ "$(wc -w < "${node}/device/capabilities/key" 2>/dev/null)" -ge 3 ] 2>/dev/null || continue
		holders="$(find /proc/[0-9]*/fd -lname "/dev/input/${node##*/}" 2>/dev/null \
			| cut -d/ -f3 | sort -u | while read -r pid; do sed -n 's/^Name:[[:space:]]*//p' "/proc/${pid}/status" 2>/dev/null; done \
			| sort -u | tr '\n' ',' | sed 's/,$//')"
		echo "${node##*/}: $(cat "${node}/device/name") (held by: ${holders:-none visible})"
		field_fact device "source=evdev" "name=$(cut -c1-60 < "${node}/device/name")" "node=${node##*/}" \
			"vendor_id=$(cat "${node}/device/id/vendor" 2>/dev/null)" "product_id=$(cat "${node}/device/id/product" 2>/dev/null)" \
			keyboard=yes "holders=${holders:-none_visible}" grabbed=unknown
	done
}

# Prints the uinput, evdev and group access the daemon needs.
field_linux_permissions() {
	local total=0 readable=0 node
	if [ -w /dev/uinput ]; then
		field_fact permission name=uinput_write state=granted subject=/dev/uinput
	else
		field_fact permission name=uinput_write state=denied subject=/dev/uinput "detail=the daemon cannot type"
	fi
	for node in /dev/input/event*; do
		[ -e "${node}" ] || continue
		total=$((total + 1))
		[ -r "${node}" ] && readable=$((readable + 1))
	done
	if [ "${total}" -gt 0 ] && [ "${readable}" -eq "${total}" ]; then
		field_fact permission name=evdev_read state=granted "subject=${readable}/${total} nodes"
	elif [ "${readable}" -gt 0 ]; then
		field_fact permission name=evdev_read state=partial "subject=${readable}/${total} nodes"
	else
		field_fact permission name=evdev_read state=denied "subject=${readable}/${total} nodes" "detail=the daemon reads no keyboard"
	fi
	if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input; then
		field_fact permission name=input_group state=granted subject=user
	else
		field_fact permission name=input_group state=absent subject=user "detail=evdev access then rests on udev rules"
	fi
	echo "groups: $(id -nG 2>/dev/null)"
	ls -l /dev/uinput 2>&1 || echo "no /dev/uinput"
}

# Prints the environment facts env.json summarises.
field_linux_environment() {
	local displays=0 status power=unknown supply
	for status in /sys/class/drm/card*-*/status; do
		[ "$(cat "${status}" 2>/dev/null)" = connected ] && displays=$((displays + 1))
	done
	for supply in /sys/class/power_supply/*; do
		[ "$(cat "${supply}/type" 2>/dev/null)" = Mains ] || continue
		[ "$(cat "${supply}/online" 2>/dev/null)" = 1 ] && power=ac || power=battery
	done
	field_fact env "os_name=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null)" \
		"os_build=$(uname -r)" "arch=$(uname -m)" \
		"model=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)" \
		"cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)" \
		"memory_gb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null)" \
		"displays=${displays}" "session=${XDG_SESSION_TYPE:-unknown}" "desktop=${XDG_CURRENT_DESKTOP:-unknown}" \
		"locale=${LANG:-unknown}" "power=${power}" \
		"virtual_machine=$(systemd-detect-virt 2>/dev/null || echo none)" \
		"selinux=$(getenforce 2>/dev/null || echo absent)" \
		"apparmor=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo absent)" \
		"container=$([ -e /.dockerenv ] || [ -e /run/.containerenv ] && echo yes || echo no)" \
		"uptime=$(awk '{ printf "%d min", $1 / 60 }' /proc/uptime 2>/dev/null)"
}

# Measures the CPU each daemon process spends over a quiet window and lists
# the busiest processes of the machine meanwhile.
field_linux_idle_cpu() {
	local pids pid tck before after name
	tck="$(getconf CLK_TCK 2>/dev/null || echo 100)"
	pids="$(pgrep -f "${FIELD_DAEMON_SCRIPT}|ydotoold" 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ')"
	# Without a daemon the window still runs: the busiest processes of an
	# idle desktop are evidence too.
	[ -n "${pids// /}" ] || echo "no daemon process: only the busiest processes are listed"
	echo "quiet window of ${FIELD_IDLE_SECONDS} s"
	for pid in ${pids}; do
		eval "before_${pid}=$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{ print $12 + $13 }')"
	done
	sleep "${FIELD_IDLE_SECONDS}"
	for pid in ${pids}; do
		[ -r "/proc/${pid}/stat" ] || continue
		name="$(sed -n 's/^Name:[[:space:]]*//p' "/proc/${pid}/status")"
		eval "before=\${before_${pid}:-0}"
		after="$(sed 's/^.*) //' "/proc/${pid}/stat" | awk '{ print $12 + $13 }')"
		echo "${name} (pid ${pid}): $(( (after - before) * 1000 / tck )) ms"
		field_fact cpu window=idle "name=${name}" "pid=${pid}" "cpu_ms=$(( (after - before) * 1000 / tck ))" \
			"window_ms=$((FIELD_IDLE_SECONDS * 1000))" \
			"percent=$(awk -v d="$((after - before))" -v t="${tck}" -v w="${FIELD_IDLE_SECONDS}" 'BEGIN { if (w > 0) printf "%.2f", 100 * d / t / w; else print 0 }')" \
			"rss_kb=$(awk '/^VmRSS:/ { print $2 }' "/proc/${pid}/status")"
	done
	echo "== busiest processes (top, second sample)"
	top -b -n 2 -d 3 -w 160 2>/dev/null | awk '/^ *PID/ { n++ } n == 2' | head -n 15 | awk '{ print $1, $9, $10, $12 }'
}

# Prints the daemon unit's state, restart count and start time.
field_linux_service_state() {
	local unit
	for unit in $(systemctl --user list-units --all --plain --no-legend 'ergopti*' 2>/dev/null | awk '{ print $1 }'); do
		echo "== ${unit}"
		systemctl --user show "${unit}" -p ActiveState,SubState,Result,NRestarts,ExecMainStartTimestamp,ExecMainPID,ExecMainStatus 2>&1
	done
}

# Prints the owner, mode and size of Ergopti's folders (no content).
field_linux_app_folders() {
	local dir
	for dir in "${HOME}/.local/bin/ergopti-hotstrings" "${XDG_DATA_HOME:-${HOME}/.local/share}/ergopti" \
		"${XDG_CONFIG_HOME:-${HOME}/.config}/ergopti" "${XDG_STATE_HOME:-${HOME}/.local/state}/ergopti" \
		"${XDG_CACHE_HOME:-${HOME}/.cache}/ergopti"; do
		if [ -e "${dir}" ]; then
			printf '%s  %s\n' "$(ls -ld "${dir}" 2>&1)" "$(du -sh "${dir}" 2>/dev/null | cut -f1)"
		else
			echo "absent: ${dir}"
		fi
	done
}
