#!/usr/bin/env bash
# tools/dev/field-report-steps.sh

# ==============================================================================
# MODULE: Field report step runner (progress, heartbeat, bound, timing)
# DESCRIPTION:
# The step runner the macOS and Linux field report collectors share
# (tools/dev/collect-macos-field-report.sh, collect-linux-field-report.sh); the
# Windows collector (collect-windows-field-report.ps1) follows the same rules
# in PowerShell. A tester could not tell a silent step from a hang (the
# input-source probe of the 2026-11-15 macOS report ran for minutes without a
# line), and the report could not say which step took the time.
#
# FEATURES & RATIONALE:
# 1. Every step prints "step k/N <name>" when it starts, with the duration the
#    previous report of this OS measured for it when there is one (its ETA),
#    then ✅ or ❌ with its own duration when it ends.
# 2. A step still running after FIELD_HEARTBEAT_SECONDS prints a heartbeat
#    line at that period: the elapsed time, the last line of its output and,
#    when the step waits for a person (password, System Settings), its hint
#    again, so a waiting step never reads as a hung one.
# 3. A bounded step is stopped at its bound (TERM, then KILL two seconds
#    later); macOS has no timeout(1), so the bound is a watchdog here.
# 4. Every step, and every phase the collector times itself (the field run,
#    the guided steps, the analysis), appends one line to step_times.tsv:
#    name, kind, start, end, status, budget (epoch seconds). A step with no
#    bound gets FIELD_STEP_DEFAULT_BUDGET_SECONDS as its budget;
#    tools/dev/field-report-facts.py lists the steps over their budget.
# 5. Background helpers (the heartbeat ticker, a bounded step's watchdog, the
#    instance sampler) never hold the collector's standard output after it
#    stops them: they write through /dev/null children, and
#    field_steps_stop_background ends them from the interrupt trap.
#
# The caller sources it after field-report-git.sh and calls field_steps_begin
# once the report folder exists (uses out, steps, log). Bash 3.2 compatible:
# the macOS collector runs under the system bash. Sourced only.
# ==============================================================================

# How often a running step says it is still alive; the contract tests shorten it.
FIELD_HEARTBEAT_SECONDS="${FIELD_HEARTBEAT_SECONDS_OVERRIDE:-15}"
# The budget of a step that declares no bound: a fact step answers in seconds.
FIELD_STEP_DEFAULT_BUDGET_SECONDS=30
# The person-facing hint a step repeats in its heartbeat (set around a step).
FIELD_STEP_HINT=""
FIELD_STEP_INDEX=0
FIELD_STEP_TOTAL=0
FIELD_STEP_TICKER=""
FIELD_STEP_BOUNDED=""
FIELD_STEP_WATCHDOG=""
FIELD_SAMPLER_PID=""
FIELD_MAIN_PID=""
FIELD_PREVIOUS_TIMES=""

# Prepares the step counters, the timing file and the previous durations.
# $1: the collector script (its step calls are counted for N), $2: OS tag.
field_steps_begin() {
	local script="$1" tag="$2" previous
	FIELD_MAIN_PID="$$"
	FIELD_STEP_TIMES="${out}/step_times.tsv"
	printf 'name\tkind\tstart\tend\tstatus\tbudget\n' > "${FIELD_STEP_TIMES}"
	# N counts the step calls of the collector and of its diagnostics library;
	# a step that does not apply on this machine leaves k below N, never above.
	FIELD_STEP_TOTAL="$(cat "${script}" "${FIELD_STEPS_EXTRA_SOURCES:-/dev/null}" 2>/dev/null \
		| grep -cE '^[[:space:]]*(step|bstep|loud_step) [a-z"]')"
	# The ETA of each step is what the previous report of this OS measured.
	previous="$(ls -1d "${ERGOPTI_FIELD_REPORT_FOLDER}/${tag}-"* 2>/dev/null | grep -v "/${tag}-${stamp}\$" | sort | tail -n 1)"
	FIELD_PREVIOUS_TIMES=""
	if [ -n "${previous}" ]; then
		FIELD_PREVIOUS_TIMES="$(find "${previous}" -name step_times.tsv -print 2>/dev/null | head -n 1)"
	fi
}

# Prints the seconds the previous report measured for a step, or nothing.
field_step_eta() {
	[ -n "${FIELD_PREVIOUS_TIMES}" ] && [ -f "${FIELD_PREVIOUS_TIMES}" ] || return 0
	awk -F '\t' -v name="$1" '$1 == name && $3 ~ /^[0-9.]+$/ { printf "%d", $4 - $3; exit }' "${FIELD_PREVIOUS_TIMES}"
}

# Appends one timing line. $1 name, $2 kind, $3 start, $4 end, $5 status, $6 budget.
field_step_time() {
	[ -n "${FIELD_STEP_TIMES:-}" ] || return 0
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "${FIELD_STEP_TIMES}"
}

# Starts the heartbeat of a running step. $1 name, $2 output file, $3 start.
field_step_ticker_start() {
	local name="$1" file="$2" started="$3"
	(
		while sleep "${FIELD_HEARTBEAT_SECONDS}" </dev/null >/dev/null 2>&1; do
			kill -0 "${FIELD_MAIN_PID}" 2>/dev/null || exit 0
			last="$(tail -n 1 "${file}" 2>/dev/null | tr -d '\r' | cut -c1-100)"
			log "  ... ${name} still running ($(( $(date +%s) - started )) s)${last:+: ${last}}"
			[ -z "${FIELD_STEP_HINT}" ] || log "  ... waiting for you: ${FIELD_STEP_HINT}"
		done
	) &
	FIELD_STEP_TICKER=$!
}

# Stops the heartbeat started last.
field_step_ticker_stop() {
	[ -n "${FIELD_STEP_TICKER}" ] || return 0
	kill "${FIELD_STEP_TICKER}" 2>/dev/null
	wait "${FIELD_STEP_TICKER}" 2>/dev/null
	FIELD_STEP_TICKER=""
}

# Runs one step: progress line, heartbeat, optional bound, timing, steps.txt.
# $1 name, $2 bound in seconds (0: none), then the command. Returns its status.
field_step_run() {
	local name="$1" bound="$2"; shift 2
	local file="${out}/${name}.txt" started ended status eta budget limit=""
	FIELD_STEP_INDEX=$((FIELD_STEP_INDEX + 1))
	eta="$(field_step_eta "${name}")"
	[ "${bound}" -gt 0 ] && limit=", at most ${bound} s"
	log "▶ step ${FIELD_STEP_INDEX}/${FIELD_STEP_TOTAL} ${name}${eta:+ (about ${eta} s last time)}${limit}"
	[ -z "${FIELD_STEP_HINT}" ] || log "  waiting for you: ${FIELD_STEP_HINT}"
	started="$(date +%s)"
	field_step_ticker_start "${name}" "${file}" "${started}"
	if [ "${bound}" -gt 0 ]; then
		"$@" > "${file}" 2>&1 &
		FIELD_STEP_BOUNDED=$!
		(
			sleep "${bound}" </dev/null >/dev/null 2>&1
			kill -TERM "${FIELD_STEP_BOUNDED}" 2>/dev/null
			sleep 2 </dev/null >/dev/null 2>&1
			kill -KILL "${FIELD_STEP_BOUNDED}" 2>/dev/null
		) </dev/null >/dev/null 2>&1 &
		FIELD_STEP_WATCHDOG=$!
		wait "${FIELD_STEP_BOUNDED}"
		status=$?
		kill "${FIELD_STEP_WATCHDOG}" 2>/dev/null
		wait "${FIELD_STEP_WATCHDOG}" 2>/dev/null
		FIELD_STEP_BOUNDED="" FIELD_STEP_WATCHDOG=""
		budget="${bound}"
	else
		"$@" > "${file}" 2>&1
		status=$?
		# A long step without a bound names its own budget (FIELD_STEP_BUDGET=...).
		budget="${FIELD_STEP_BUDGET:-${FIELD_STEP_DEFAULT_BUDGET_SECONDS}}"
	fi
	field_step_ticker_stop
	ended="$(date +%s)"
	if [ "${bound}" -gt 0 ] && [ $((ended - started)) -ge "${bound}" ]; then
		printf '\n[field-report] stopped at its bound of %s s\n' "${bound}" >> "${file}"
	fi
	printf '%-28s exit=%s\n' "${name}" "${status}" >> "${steps}"
	field_step_time "${name}" collector "${started}" "${ended}" "${status}" "${budget}"
	if [ "${status}" -eq 0 ]; then
		log "  ✅ ${name} ($((ended - started)) s)"
	else
		log "  ❌ ${name} exited ${status} ($((ended - started)) s, kept in ${file})"
	fi
	return "${status}"
}

# Times a phase the collector runs itself (not through field_step_run).
# $1 name, $2 start (epoch), $3 status, $4 budget in seconds.
field_phase_done() {
	local ended
	ended="$(date +%s)"
	field_step_time "$1" phase "$2" "${ended}" "$3" "$4"
}

# Ends every background helper; the interrupt trap and finalize call it.
field_steps_stop_background() {
	local pid
	for pid in "${FIELD_STEP_TICKER}" "${FIELD_STEP_WATCHDOG}" "${FIELD_STEP_BOUNDED}" "${FIELD_SAMPLER_PID}"; do
		[ -n "${pid}" ] && kill "${pid}" 2>/dev/null
	done
	FIELD_STEP_TICKER="" FIELD_STEP_WATCHDOG="" FIELD_STEP_BOUNDED="" FIELD_SAMPLER_PID=""
}

# Starts the periodic instance sampler: every FIELD_SAMPLER_SECONDS it runs the
# caller's sampling function with "sample" and appends its fact lines to
# instances_timeline.txt, so a second driver or a restart during the field run
# is on record. $1: the function (it prints fact lines for one phase).
field_sampler_start() {
	local sampler="$1" file="${out}/instances_timeline.txt"
	(
		while :; do
			kill -0 "${FIELD_MAIN_PID}" 2>/dev/null || exit 0
			"${sampler}" sample >> "${file}" 2>/dev/null </dev/null
			sleep "${FIELD_SAMPLER_SECONDS:-10}" </dev/null >/dev/null 2>&1
		done
	) </dev/null >/dev/null 2>&1 &
	FIELD_SAMPLER_PID=$!
}

# Stops the sampler.
field_sampler_stop() {
	[ -n "${FIELD_SAMPLER_PID}" ] || return 0
	kill "${FIELD_SAMPLER_PID}" 2>/dev/null
	wait "${FIELD_SAMPLER_PID}" 2>/dev/null
	FIELD_SAMPLER_PID=""
}

# Builds env.json and the timeline from the fact lines and timings, then
# records the step (uses REPO_ROOT, out, steps). $1: OS tag (mac, linux).
field_report_facts() {
	local started
	started="$(date +%s)"
	python3 "${REPO_ROOT}/tools/dev/field-report-facts.py" build "${out}" --os "$1" > "${out}/facts_console.txt" 2>&1
	local status=$?
	cat "${out}/facts_console.txt"
	printf '%-28s exit=%s\n' "facts" "${status}" >> "${steps}"
	[ "${status}" -eq 0 ] || log "step 'facts' exited ${status} (kept in ${out}/facts_console.txt)"
	return 0
}
