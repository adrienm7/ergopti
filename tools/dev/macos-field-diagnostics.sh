#!/usr/bin/env bash
# tools/dev/macos-field-diagnostics.sh

# ==============================================================================
# MODULE: macOS field report diagnostics
# DESCRIPTION:
# The machine facts tools/dev/collect-macos-field-report.sh adds to each
# report so a failure the logs cannot explain still has its context: the
# 2026-11-15 report counted keys three times, typed one extra byte, spent
# 785 ms of idle CPU no timer explained and could not say whether a second
# Ergopti (release and developer app) or a full Karabiner-Elements ran beside
# the driver. Each function prints raw evidence plus machine-readable lines
# "fact<TAB><type><TAB>key=value..." that tools/dev/field-report-facts.py
# turns into env.json, which the analysis reads.
#
# FEATURES & RATIONALE:
# 1. Instances: every Ergopti launcher, embedded Hammerspoon and owned
#    runtime helper with its path, version, bundle id, team, start time,
#    parent, cumulative CPU and memory, at each phase and by the sampler.
# 2. Other remappers, text expanders and event-tap users (Karabiner-Elements
#    with its device grabs and a summary of its configuration, BetterTouchTool,
#    Keyboard Maestro, a standalone Hammerspoon, espanso...), the Secure Event
#    Input owner, the privacy permissions the TCC databases grant when the
#    terminal may read them (never written), the keyboards and input sources.
# 3. The idle CPU of each driver process over a quiet window, with a `sample`
#    of the embedded Hammerspoon when it spends more than the idle budget.
# 4. The unified log of Ergopti's processes, tccd and launchd since the run
#    started, the launchd jobs, the app folders, the installer log lines and
#    the day's crash reports of the helpers.
# 5. Never printed: an address, a serial number, a Bluetooth address, typed
#    text or a secret. Every call is bounded by the collector's step runner.
#
# Sourced only (after identifiers.sh); defines functions and runs nothing.
# Bash 3.2 compatible.
# ==============================================================================

# The quiet window of the idle CPU step; the contract test shortens it.
FIELD_IDLE_SECONDS="${FIELD_IDLE_SECONDS_OVERRIDE:-20}"
# The owned runtime's install folder and the Karabiner-Elements locations.
FIELD_OWNED_RUNTIME_DIR="/Library/Application Support/ErgoptiPlus/Runtime"
FIELD_KARABINER_APP="/Applications/Karabiner-Elements.app"
FIELD_KARABINER_CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
# Every process the instance facts follow (pgrep -f regex).
FIELD_INSTANCE_PATTERN="${ERGOPTI_APP_NAME}|Hammerspoon|${FIELD_OWNED_RUNTIME_DIR}"

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

# Converts ps cumulative CPU time ([[dd-]hh:]mm:ss[.cc]) to seconds.
field_cpu_seconds() {
	printf '%s\n' "$1" | awk -F'[-:]' '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'
}

# Prints the .app bundle a path belongs to (the outermost one is not wanted:
# the embedded Hammerspoon.app is its own bundle).
field_bundle_of() {
	printf '%s\n' "$1" | sed -n 's#^\(.*\.app\)/Contents/.*$#\1#p'
}

# Reads one Info.plist key of a bundle.
field_plist_value() {
	plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

# Prints the instance facts of one phase (start, before_run, sample, end).
# A sample omits the signature, which costs a codesign call per process.
field_mac_instances() {
	local phase="$1" now pid path ppid started cpu rss role name origin bundle version id team parent
	now="$(date +%s)"
	field_fact sample "phase=${phase}" "t=${now}"
	for pid in $(pgrep -f "${FIELD_INSTANCE_PATTERN}" 2>/dev/null); do
		[ "${pid}" = "$$" ] && continue
		path="$(ps -p "${pid}" -o comm= 2>/dev/null)"
		[ -n "${path}" ] || continue
		case "${path}" in
			*"/Contents/MacOS/${ERGOPTI_APP_NAME}") role=driver; name="${ERGOPTI_APP_NAME}" ;;
			*"${ERGOPTI_APP_BUNDLE}/Contents/Frameworks/Hammerspoon.app/"*) role=engine; name=Hammerspoon ;;
			*"/Hammerspoon.app/Contents/MacOS/Hammerspoon") role=remapper; name="Hammerspoon (standalone)" ;;
			*"${ERGOPTI_APP_NAME}"*|"${FIELD_OWNED_RUNTIME_DIR}"*) role=helper; name="${path##*/}" ;;
			*) continue ;;
		esac
		case "${path}" in
			/Applications/*) origin=release ;;
			*/build/macos/*) origin=dev ;;
			"${FIELD_OWNED_RUNTIME_DIR}"*) origin=owned_runtime ;;
			*) origin=other ;;
		esac
		ppid="$(ps -p "${pid}" -o ppid= 2>/dev/null | tr -d ' ')"
		started="$(ps -p "${pid}" -o lstart= 2>/dev/null | sed 's/  */ /g; s/^ //')"
		cpu="$(field_cpu_seconds "$(ps -p "${pid}" -o time= 2>/dev/null | tr -d ' ')")"
		rss="$(ps -p "${pid}" -o rss= 2>/dev/null | tr -d ' ')"
		parent="$(ps -p "${ppid:-1}" -o comm= 2>/dev/null | sed 's#.*/##')"
		bundle="$(field_bundle_of "${path}")"
		version="" id="" team=""
		if [ -n "${bundle}" ]; then
			version="$(field_plist_value "${bundle}" CFBundleShortVersionString)"
			id="$(field_plist_value "${bundle}" CFBundleIdentifier)"
			if [ "${phase}" != sample ]; then
				team="$(codesign -dv "${bundle}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
			fi
		fi
		field_fact instance "phase=${phase}" "t=${now}" "role=${role}" "name=${name}" "pid=${pid}" \
			"ppid=${ppid}" "parent=${parent}" "started=${started}" "cpu_s=${cpu}" "rss_kb=${rss}" \
			"origin=${origin}" "path=${path}" "version=${version}" "bundle_id=${id}" "team=${team}"
	done
}

# Prints the other remappers, text expanders and event-tap users, with
# Karabiner-Elements in detail: version, its processes beside Ergopti's own
# runtime, the devices it grabs and a summary of its configuration.
# $1: clone root (for the summary helper).
field_mac_remappers() {
	local root="$1" version core owned conflict tmp lines line name
	version="absent"
	[ -d "${FIELD_KARABINER_APP}" ] && version="$(field_plist_value "${FIELD_KARABINER_APP}" CFBundleShortVersionString)"
	core="$(pgrep -f "org.pqrs/Karabiner-Elements/Karabiner-Core-Service" 2>/dev/null | wc -l | tr -d ' ')"
	owned="$(pgrep -f "${FIELD_OWNED_RUNTIME_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
	# Without Ergopti's own runtime, Karabiner-Elements is the driver's backend.
	conflict=no
	if [ -e "/Library/LaunchDaemons/${ERGOPTI_SERVICE_LABEL_MACOS_CORE}.plist" ] || [ "${owned}" -gt 0 ]; then
		[ "${core}" -gt 0 ] && conflict=yes
	fi
	echo "== Karabiner-Elements"
	echo "app: ${version}; Karabiner-Core-Service processes: ${core}; owned runtime processes: ${owned}"
	field_fact remapper "name=Karabiner-Elements" "running=$([ "${core}" -gt 0 ] && echo yes || echo no)" \
		"version=${version}" "conflict=${conflict}" "detail=core_services=${core} owned_runtime_processes=${owned}"
	if [ -x "${FIELD_KARABINER_CLI}" ]; then
		echo "karabiner_cli: $("${FIELD_KARABINER_CLI}" --version 2>&1 | head -n 1)"
		tmp="$(mktemp "${TMPDIR:-/tmp}/ergopti-karabiner-devices.XXXXXX")"
		"${FIELD_KARABINER_CLI}" --list-connected-devices > "${tmp}" 2>/dev/null || : > "${tmp}"
		echo "== Karabiner-Elements configuration (counts and device flags only)"
		if [ -f "${HOME}/.config/karabiner/karabiner.json" ]; then
			python3 "${root}/tools/dev/field-report-facts.py" karabiner "${HOME}/.config/karabiner/karabiner.json" \
				"$([ -s "${tmp}" ] && printf '%s' "${tmp}")"
		else
			echo "no karabiner.json"
		fi
		rm -f "${tmp}"
	fi
	echo "== Other remappers, text expanders and event-tap users"
	# One filtered listing; each match is classified by its executable name.
	lines="$(pgrep -lif "BetterTouchTool|Keyboard Maestro Engine|/Hammerspoon.app/Contents/MacOS/Hammerspoon|kanata|skhd|Keyboard Cowboy|espanso|TextExpander|aText|Typinator|Raycast|Alfred|logioptionsplus_agent|Logi Options|SteerMouse|USB Overdrive|BetterMouse|Karabiner-EventViewer|ShortcutDetective|Rocket Typist" 2>/dev/null)"
	if [ -z "${lines}" ]; then
		echo "none running"
		return 0
	fi
	printf '%s\n' "${lines}" | while IFS= read -r line; do
		case "${line}" in
			*"${ERGOPTI_APP_BUNDLE}"*) continue ;;
			*BetterTouchTool*) name=BetterTouchTool ;;
			*"Keyboard Maestro Engine"*) name="Keyboard Maestro" ;;
			*Hammerspoon*) name="Hammerspoon (standalone)" ;;
			*[Kk]anata*) name=kanata ;;
			*skhd*) name=skhd ;;
			*"Keyboard Cowboy"*) name="Keyboard Cowboy" ;;
			*espanso*) name=espanso ;;
			*TextExpander*) name=TextExpander ;;
			*aText*) name=aText ;;
			*Typinator*) name=Typinator ;;
			*"Rocket Typist"*) name="Rocket Typist" ;;
			*Raycast*) name=Raycast ;;
			*Alfred*) name=Alfred ;;
			*[Ll]ogi*) name="Logi Options+" ;;
			*SteerMouse*) name=SteerMouse ;;
			*"USB Overdrive"*) name="USB Overdrive" ;;
			*BetterMouse*) name=BetterMouse ;;
			*) name="${line#* }"; name="${name##*/}" ;;
		esac
		echo "running: ${name} (pid ${line%% *})"
		field_fact remapper "name=${name}" running=yes conflict=yes "detail=pid=${line%% *}"
	done | awk '!seen[$0]++'
}

# Prints the privacy permissions the TCC databases grant to Ergopti,
# Hammerspoon and Karabiner, read only; without Full Disk Access for the
# terminal they are unreadable, which is said, never guessed.
field_mac_permissions() {
	local db rows label query
	query="SELECT service, client, auth_value FROM access WHERE service IN ('kTCCServiceAccessibility','kTCCServiceListenEvent','kTCCServicePostEvent','kTCCServiceSystemPolicyAllFiles') AND (client LIKE '%ergoptiplus%' OR client LIKE '%hammerspoon%' OR client LIKE '%pqrs%' OR client LIKE '%karabiner%');"
	for db in "/Library/Application Support/com.apple.TCC/TCC.db" "${HOME}/Library/Application Support/com.apple.TCC/TCC.db"; do
		label=system
		case "${db}" in "${HOME}"*) label=user ;; esac
		echo "== ${label} TCC database"
		if ! rows="$(sqlite3 -readonly -separator '|' "${db}" "${query}" 2>&1)"; then
			echo "unreadable: ${rows}" | head -n 2
			field_fact permission "name=tcc_${label}" state=unknown subject=all \
				"detail=the terminal has no Full Disk Access, so the ${label} TCC database is unreadable"
			continue
		fi
		[ -n "${rows}" ] || { echo "no Ergopti, Hammerspoon or Karabiner entry"; continue; }
		printf '%s\n' "${rows}" | while IFS='|' read -r service client value; do
			case "${value}" in 2) state=granted ;; 3) state=limited ;; 0) state=denied ;; *) state="value_${value}" ;; esac
			echo "${service} ${client}: ${state}"
			field_fact permission "name=${service#kTCCService}" "state=${state}" "subject=${client}" "detail=${label} TCC"
		done
	done
	echo "== Secure Event Input (an app holding it hides every key from event taps)"
	local secure
	secure="$(ioreg -l -d 1 -w 0 2>/dev/null | grep -oE 'kCGSSessionSecureInputPID"=[0-9]+' | head -n 1 | sed 's/.*=//')"
	if [ -n "${secure}" ] && [ "${secure}" != 0 ]; then
		echo "held by pid ${secure}: $(ps -p "${secure}" -o comm= 2>/dev/null | sed 's#.*/##')"
		field_fact permission name=secure_event_input state=held_by_other \
			"subject=$(ps -p "${secure}" -o comm= 2>/dev/null | sed 's#.*/##')" "detail=pid=${secure}"
	else
		echo "not held"
		field_fact permission name=secure_event_input state=free subject=none
	fi
}

# Prints the keyboards the system sees (names, vendor and product ids,
# transport; no serial, no address) and the active input source.
field_mac_input_devices() {
	local root="$1" tmp current
	tmp="$(mktemp "${TMPDIR:-/tmp}/ergopti-hid.XXXXXX")"
	ioreg -a -r -c IOHIDDevice -d 1 > "${tmp}" 2>/dev/null
	python3 "${root}/tools/dev/field-report-facts.py" hid "${tmp}"
	rm -f "${tmp}"
	current="$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)"
	echo "current input source: ${current:-unknown}"
	field_fact layout "id=${current:-unknown}" active=yes
}

# Prints the environment facts env.json summarises.
field_mac_environment() {
	local displays power vm sip translated utun
	displays="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")"
	power="$(pmset -g batt 2>/dev/null | head -n 1 | sed -n "s/.*'\(.*\)'.*/\1/p")"
	vm="$(sysctl -n kern.hv_vmm_present 2>/dev/null)"
	sip="$(csrutil status 2>/dev/null | sed -n 's/.*status: \([a-z]*\).*/\1/p')"
	translated="$(sysctl -n sysctl.proc_translated 2>/dev/null)"
	utun="$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -c '^utun')"
	field_fact env "os_name=macOS" "os_version=$(sw_vers -productVersion 2>/dev/null)" \
		"os_build=$(sw_vers -buildVersion 2>/dev/null)" "arch=$(uname -m)" \
		"model=$(sysctl -n hw.model 2>/dev/null)" "cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" \
		"memory_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))" "displays=${displays}" \
		"locale=$(defaults read -g AppleLocale 2>/dev/null)" \
		"language=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[ ",]//gp')" \
		"power=${power:-unknown}" "low_power_mode=$(pmset -g 2>/dev/null | awk '/lowpowermode/ { print $2 }')" \
		"virtual_machine=$([ "${vm}" = 1 ] && echo yes || echo no)" "sip=${sip:-unknown}" \
		"rosetta_shell=$([ "${translated}" = 1 ] && echo yes || echo no)" "vpn_tunnels=${utun}" \
		"default_route=$(route -n get default >/dev/null 2>&1 && echo yes || echo no)" \
		"security_agents=$(systemextensionsctl list 2>/dev/null | grep -v -i com.apple | grep -c '\[activated')" \
		"uptime=$(uptime | sed 's/.*up \([^,]*\),.*/\1/')"
}

# Measures the CPU each driver process spends over a quiet window, lists the
# busiest processes with their wakeups, and samples the embedded Hammerspoon
# when it spent more than the idle budget. $1: clone root.
field_mac_idle_cpu() {
	local root="$1" pids pid name before after percent budget hs="" hs_percent=0 tmp
	budget="$(sed -n 's/^M\.IDLE_CPU_PERCENT_MAX = \([0-9.]*\)$/\1/p' "${root}/static/ergopti_plus/macos/infra/field_check_session.lua")"
	pids="$(pgrep -f "${FIELD_INSTANCE_PATTERN}|org.pqrs" 2>/dev/null | tr '\n' ' ')"
	# Without a driver the window still runs: the busiest processes of an
	# idle Mac are evidence too.
	[ -n "${pids// /}" ] || echo "no driver process: only the busiest processes are listed"
	echo "quiet window of ${FIELD_IDLE_SECONDS} s; idle budget ${budget:-unknown} % (field_check_session.lua)"
	for pid in ${pids}; do
		eval "before_${pid}=$(field_cpu_seconds "$(ps -p "${pid}" -o time= 2>/dev/null | tr -d ' ')")"
	done
	sleep "${FIELD_IDLE_SECONDS}"
	for pid in ${pids}; do
		name="$(ps -p "${pid}" -o comm= 2>/dev/null | sed 's#.*/##')"
		[ -n "${name}" ] || continue
		eval "before=\${before_${pid}}"
		after="$(field_cpu_seconds "$(ps -p "${pid}" -o time= 2>/dev/null | tr -d ' ')")"
		percent="$(awk -v a="${after}" -v b="${before}" -v w="${FIELD_IDLE_SECONDS}" 'BEGIN { if (w > 0) printf "%.2f", 100 * (a - b) / w; else print 0 }')"
		echo "${name} (pid ${pid}): $(awk -v a="${after}" -v b="${before}" 'BEGIN { printf "%d", 1000 * (a - b) }') ms, ${percent} %"
		field_fact cpu window=idle "name=${name}" "pid=${pid}" \
			"cpu_ms=$(awk -v a="${after}" -v b="${before}" 'BEGIN { printf "%d", 1000 * (a - b) }')" \
			"window_ms=$((FIELD_IDLE_SECONDS * 1000))" "percent=${percent}" \
			"rss_kb=$(ps -p "${pid}" -o rss= 2>/dev/null | tr -d ' ')" "budget_percent=${budget}"
		case "$(ps -p "${pid}" -o comm= 2>/dev/null)" in
			*"${ERGOPTI_APP_BUNDLE}/Contents/Frameworks/Hammerspoon.app/"*) hs="${pid}"; hs_percent="${percent}" ;;
		esac
	done
	echo "== busiest processes (top, second sample: CPU %, idle wakeups, energy)"
	top -l 2 -s 3 -n 12 -o cpu -stats pid,command,cpu,idlew,power,time 2>&1 | awk '/^PID/ { n++ } n == 2'
	if [ -n "${hs}" ] && [ -n "${budget}" ] && awk -v p="${hs_percent}" -v b="${budget}" 'BEGIN { exit !(p > b) }'; then
		echo "== sample of the embedded Hammerspoon (${hs_percent} % > ${budget} %), 3 s"
		tmp="$(mktemp "${TMPDIR:-/tmp}/ergopti-sample.XXXXXX")"
		sample "${hs}" 3 -mayDie -file "${tmp}" >/dev/null 2>&1
		sed -n '/^Sort by top of stack/,$p' "${tmp}" | head -n 60
		sed -n '/^Call graph:/,/^Total number in stack/p' "${tmp}" | head -n 150
		rm -f "${tmp}"
	fi
}

# Prints the unified log of Ergopti's processes since the run started: their
# errors and faults, every message of Ergopti's own subsystems, tccd's
# decisions about Ergopti, Hammerspoon or Karabiner, and launchd's lines about
# Ergopti's jobs. Hammerspoon's ordinary messages stay out: they can carry the
# console's text. $1: start epoch.
field_mac_unified_log() {
	local start
	start="$(date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || return 1
	/usr/bin/log show --style compact --start "${start}" --predicate '(subsystem BEGINSWITH "com.ergoptiplus") OR (process == "tccd" AND (eventMessage CONTAINS[c] "ergoptiplus" OR eventMessage CONTAINS[c] "hammerspoon" OR eventMessage CONTAINS[c] "karabiner")) OR (process == "launchd" AND eventMessage CONTAINS[c] "ergoptiplus") OR ((process BEGINSWITH "ErgoptiPlus" OR process == "Hammerspoon" OR process BEGINSWITH "Karabiner" OR process BEGINSWITH "karabiner") AND messageType IN {16, 17})' 2>&1 \
		| tail -n 3000
}

# Prints the state, pid and last exit of Ergopti's launchd jobs and the
# launchd entries of Ergopti, Hammerspoon and Karabiner.
field_mac_services() {
	local label domain
	for label in "${ERGOPTI_SERVICE_LABEL_MACOS_CORE}" "${ERGOPTI_SERVICE_LABEL_MACOS_VIRTUAL_HID}" \
		"${ERGOPTI_SERVICE_LABEL_MACOS_REMAP_GUARDIAN}"; do
		for domain in system "gui/$(id -u)"; do
			if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
				echo "== ${domain}/${label}"
				launchctl print "${domain}/${label}" 2>&1 | grep -E '^\s*(state|pid|last exit code|runs|program|job state) =' | head -n 8
			fi
		done
	done
	echo "== launchctl list (Ergopti, Hammerspoon, Karabiner)"
	launchctl list 2>/dev/null | grep -iE "ergopti|hammerspoon|pqrs" || echo "none"
}

# Prints the owner, mode and size of Ergopti's folders (no content).
field_mac_app_folders() {
	local dir
	for dir in "/Applications/${ERGOPTI_APP_BUNDLE}" "${HOME}/Library/Application Support/Ergopti" \
		"${HOME}/Library/Application Support/${ERGOPTI_APP_NAME}" "${HOME}/Library/Logs/ergopti_plus" \
		"/Library/Application Support/${ERGOPTI_APP_NAME}" "${HOME}/.config/karabiner"; do
		if [ -e "${dir}" ]; then
			printf '%s  %s\n' "$(ls -ld "${dir}" 2>&1)" "$(du -sh "${dir}" 2>/dev/null | cut -f1)"
		else
			echo "absent: ${dir}"
		fi
	done
	echo "== installer log lines (pkg installs of Ergopti)"
	grep -iE "ergoptiplus" /var/log/install.log 2>/dev/null | tail -n 80 || echo "none readable"
}
