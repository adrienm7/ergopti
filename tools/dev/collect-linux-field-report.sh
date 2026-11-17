#!/usr/bin/env bash
# tools/dev/collect-linux-field-report.sh

# ==============================================================================
# MODULE: Linux field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Linux desktop, the Linux
# counterpart of tools/dev/collect-macos-field-report.sh: it updates the field
# branch from its base (dev unless it was derived from another branch), gathers
# the evidence the coordinator reads (system, session, toolchain, runtime,
# input access and device facts, the driver's units, autostart, processes,
# memory, listeners, proxy settings and crash dumps, the collector's own
# checks, today's ErgoptiPlus logs, their digest and their analysis), stores
# it under docs/field-reports/, then commits and pushes
# the branch. The logs are gitignored, so they are added with `git add -f`; the
# logger already masks secrets, the home folder, e-mail addresses and personal
# names, and the branch is public, so only copies scrubbed of typed text by
# tools/dev/field-log-scrub.py leave the machine and the digests read those copies.
# The whole folder then goes through tools/dev/field-report-redact.py before the
# commit, which is refused when a trace of the user or the machine remains.
# The personal hotstrings file never travels: tools/dev/hotstring-collisions.py
# reports which of its triggers share a bundled one. The facts below have the home
# folder and the user name replaced.
#
# The analysis: tools/dev/field-log-analyse.py, the analyser the three
# collectors share, reads the scrubbed day logs and writes analysis.md and
# analysis.json at the top of the report (errors grouped by template, every
# measured duration against the budget its code declares, lifecycle events,
# check verdicts, what to fix first) and prints the verdict marks and their
# summary line: the collector's own checks (tools/dev/linux-field-shell-checks.sh),
# the field run and the tray checks clicked today.
#
# The guided and probe steps: tools/dev/field-guided.py, after the field run,
# reads the session (uinput, evdev, autostart, polkit, the focus reporter) and
# prompts the gestures of TODO « To confirm on Linux » in this terminal; the
# report ends with todo_summary.md, one verdict per TODO point
# (static/ergopti_plus/linux/diagnostics/data/field_todo_coverage.json).
#
# The machine facts (tools/dev/linux-field-diagnostics.sh): every Ergopti
# daemon and helper at the start, before the run, every FIELD_SAMPLER_SECONDS
# during it and at the end, the other remappers, text expanders and input
# methods, which processes hold each keyboard's evdev node, the uinput and
# evdev access, the machine, the idle CPU per daemon process, the unit's state
# and restarts, its journal since the collector started (scrubbed) and the app
# folders. tools/dev/field-report-facts.py turns their fact lines into
# 0_main/env.json and the step timings into 0_main/timeline.txt; the analysis
# reads both. Every step prints "step k/N", a heartbeat every 15 s while it
# runs and its duration (tools/dev/field-report-steps.sh); a new step is
# stopped at its bound.
#
# The field run: tools/dev/linux-field-run.sh asks the running daemon to run its
# Debug field checks with no window (linux/diagnostics/engine/field_run/field_run.lua, the macOS field
# run's protocol), copies one result per step into field_run/ and prints their
# marks; no click is needed.
#
# The logs folder is the one the driver itself resolves
# (settings/engine/paths.lua get_logs_dir: the paths.logs_dir override, else
# ${XDG_STATE_HOME:-~/.local/state}/ergopti/logs), asked through luajit.
#
# NOT COVERED, AND WHY:
# - A daemon that is not running gets no field run: the collector says so and
#   collects the rest. Each check also writes one "check=<id> verdict=<...>"
#   line to the day log, whether the field run or a click ran it: those lines
#   are in digest_field_checks, printed with the macOS marks (✅ pass, ❌ fail,
#   ⏭️ skip, ⌨️ needs_typing, ⚠️ other) and a summary line, also kept in
#   field_checks.txt, and the analysis marks the last run of each.
# - No diagnostics export. The health check is a tray window, with no
#   command-line form; the boot diagnostic snapshot (the one [Diagnostics]
#   line) is in the day log and digest_snapshot.
# - The topical sub-logs (ErgoptiPlus_hotstrings.log, ...) are not copied:
#   every line they hold is also in the day log.
#
# USAGE (from any branch: outside a field/ branch the collector switches to
# field/linux-<today>-<branch>, derived from that branch and created when
# missing; base.txt in the report names the base and the commit):
#   bash tools/dev/collect-linux-field-report.sh            update, collect, commit, push
#   bash tools/dev/collect-linux-field-report.sh --no-push  same, without the push
#
# Each step records its exit status in steps.txt; a failed step never hides
# the others. Ctrl-C or a TERM never loses the evidence: the collector still
# copies the logs that exist, then commits and pushes them, marked interrupted.
# ==============================================================================

set -uo pipefail

# Command substitution removes trailing LF bytes, even when they belong to a
# directory name. Capture a sentinel and remove only that final byte afterward.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "${PWD}")"
REPO_ROOT="${REPO_ROOT%.}"
# The collector keeps going after a failed step, but never without the shared
# identifiers: a missing file stops it here.
set -e
# shellcheck source=../../static/ergopti_plus/_shared/core/text/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/core/text/data/identifiers.sh"
# shellcheck source=field-report-git.sh
. "$REPO_ROOT/tools/dev/field-report-git.sh"
# shellcheck source=linux-field-shell-checks.sh
. "$REPO_ROOT/tools/dev/linux-field-shell-checks.sh"
# shellcheck source=linux-field-run.sh
. "$REPO_ROOT/tools/dev/linux-field-run.sh"
# shellcheck source=field-report-steps.sh
. "$REPO_ROOT/tools/dev/field-report-steps.sh"
# shellcheck source=linux-field-diagnostics.sh
. "$REPO_ROOT/tools/dev/linux-field-diagnostics.sh"
set +e
DRIVER_ROOT="$REPO_ROOT/static/ergopti_plus/linux"
SHARED_LUA="$REPO_ROOT/static/ergopti_plus/_shared"
BUNDLED_HOTSTRINGS="$REPO_ROOT/static/ergopti_plus/_shared/hotstrings/data/catalogue"

fail() { printf '[field-report] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[field-report] %s\n' "$*"; }

push=true
case "$#:${1:-}" in
	0:) ;;
	1:--no-push) push=false ;;
	*) fail "Expected no argument or --no-push." ;;
esac

[ "$(uname -s)" = "Linux" ] || fail "This collector runs on Linux only."
cd "${REPO_ROOT}" || fail "Cannot enter the repository root."
git rev-parse --git-dir >/dev/null 2>&1 || fail "Not inside the Ergopti clone."

field_report_enter_branch linux

# ===========================================
# ======= 1/ Update from the base ===========
# ===========================================

field_report_update_from_base "${REPO_ROOT}/tools/dev/collect-linux-field-report.sh" "$@"
field_report_open_folder linux
# Every step prints its progress and heartbeat and is timed (field-report-steps.sh).
field_steps_begin "${REPO_ROOT}/tools/dev/collect-linux-field-report.sh" linux
# The daemon journal of the run window starts here.
run_started_epoch="$(date +%s)"
# Set by the INT/TERM trap; the remaining evidence is still collected.
interrupted=false
finalized=false

# Replaces the home folder and the user name in a captured fact file.
mask_file() {
	local file="$1" text user="${USER:-$(id -un 2>/dev/null)}" home_mark='~' user_mark='<user>'
	text="$(cat "${file}"; printf '.')"
	text="${text%.}"
	[ -n "${HOME:-}" ] && [ "${HOME}" != "/" ] && text="${text//"${HOME}"/${home_mark}}"
	# A one- or two-letter name would mask ordinary words too.
	[ "${#user}" -ge 3 ] && text="${text//"${user}"/${user_mark}}"
	printf '%s' "${text}" > "${file}"
}

# Runs one named step, captures its output into a file and records its status;
# it prints its progress, its heartbeat and its duration (field_step_run).
step() {
	local name="$1"; shift
	field_step_run "${name}" 0 "$@"
	mask_file "${out}/${name}.txt"
	return 0
}

# A step stopped at its bound. $1: name, $2: bound in seconds, then the command.
bstep() {
	local name="$1" bound="$2"; shift 2
	field_step_run "${name}" "${bound}" "$@"
	mask_file "${out}/${name}.txt"
	return 0
}

# Says at once, in the terminal, when one phase saw two Ergopti daemons: the
# second one types every expansion twice. $1: the instance step's name.
warn_multiple_drivers() {
	local count
	count="$(grep -cE "^fact	instance	.*	role=driver	" "${out}/$1.txt" 2>/dev/null)"
	[ "${count:-0}" -gt 1 ] || return 0
	log "⚠️  ${count} Ergopti daemons are running at once (see $1.txt): stop the one you are not testing."
}

# Maps a check verdict to the mark the maintainer scans the output for, as the
# macOS collector does; the verdict word stays after it so the logs remain
# searchable.
verdict_mark() {
	case "$1" in
		pass) printf '✅' ;;
		fail) printf '❌' ;;
		skip) printf '⏭️' ;;
		needs_typing) printf '⌨️' ;;
		*) printf '⚠️' ;;
	esac
}

# Prints each "check=<id> verdict=<...>" line of the digest with its mark, then
# one summary line, on the terminal and in field_checks.txt of the report.
report_field_checks() {
	local digest="$1" line check verdict
	local passed=0 failed=0 skipped=0 typing=0 other=0
	: > "${out}/field_checks.txt"
	while IFS= read -r line; do
		check="$(printf '%s\n' "${line}" | sed -n 's/.*check=\([a-z_]*\) verdict=.*/\1/p')"
		verdict="$(printf '%s\n' "${line}" | sed -n 's/.*check=[a-z_]* verdict=\([^ ]*\).*/\1/p')"
		[ -n "${check}" ] || continue
		case "${verdict}" in
			pass) passed=$((passed + 1)) ;;
			fail) failed=$((failed + 1)) ;;
			skip) skipped=$((skipped + 1)) ;;
			needs_typing) typing=$((typing + 1)) ;;
			*) other=$((other + 1)) ;;
		esac
		printf '  %s field check %s: %s\n' "$(verdict_mark "${verdict}")" "${check}" "${verdict:-unreadable}" \
			| tee -a "${out}/field_checks.txt" | sed 's/^/[field-report] /'
	done < "${digest}"
	printf 'Field check summary: ✅ %d pass, ❌ %d fail, ⏭️ %d skip, ⌨️ %d needs_typing, ⚠️ %d other.\n' \
		"${passed}" "${failed}" "${skipped}" "${typing}" "${other}" \
		| tee -a "${out}/field_checks.txt" | sed 's/^/[field-report] /'
}

# Prints the logs folder the driver resolves and the log file names of
# _shared/core/fs/engine/app_dirs.lua, one per line: folder, unified prefix, errors prefix,
# extension, bootstrap log, crash reports folder, personal hotstrings file and
# the Metrics database the guided steps count rows in.
driver_log_layout() {
	LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;" \
		luajit -e '
			local dirs, files = require("core.fs.engine.app_dirs"), require("core.fs.engine.app_dirs").files
			print(require("settings.engine.paths").get_logs_dir())
			print(files.unified_prefix); print(files.errors_prefix); print(files.extension)
			print(files.bootstrap_log); print(dirs.crash_reports_dir)
			print(require("settings.engine.paths").config("personal_hotstrings.toml"))
			print(require("settings.engine.paths").metrics_path())'
}

# Copies one log into the report without the user's typed text.
scrub_log() {
	local source="$1" name
	name="$(basename "${source}")"
	if python3 "${REPO_ROOT}/tools/dev/field-log-scrub.py" "${source}" "${out}/${name}" \
		"${BUNDLED_HOTSTRINGS}"; then
		printf '%-28s copied (scrubbed)\n' "${name}" >> "${steps}"
	else
		# Never fall back to the raw log: it would publish the typed text.
		rm -f "${out}/${name}"
		printf '%-28s scrub failed, not copied\n' "${name}" >> "${steps}"
	fi
}

# Copies the logs and the digest, commits and pushes, once: from the normal end
# and from the INT/TERM trap, so an interrupted run still leaves its evidence.
finalize() {
	"${finalized}" && return 0
	finalized=true
	# No heartbeat, watchdog or sampler may outlive the collection.
	field_steps_stop_background
	local start_day today d f subject layout log_dir main errors ext bootstrap crashes personal
	local days=() day_logs=()
	# A run that crosses midnight spans two day logs: keep both, oldest first.
	start_day="${stamp%%_*}"
	today="$(date +%Y-%m-%d)"
	days=("${start_day}")
	[ "${today}" = "${start_day}" ] || days+=("${today}")
	if layout="$(driver_log_layout 2>"${out}/logs_dir.txt")"; then
		{ read -r log_dir; read -r main; read -r errors; read -r ext; read -r bootstrap; read -r crashes; read -r personal; } <<< "${layout}"
	fi
	if [ -z "${crashes:-}" ]; then
		printf '%-28s unresolved (luajit could not run settings/engine/paths.lua, see logs_dir.txt)\n' "logs" >> "${steps}"
		mask_file "${out}/logs_dir.txt"
	elif [ -d "${log_dir}" ]; then
		: > "${out}/logs_dir.txt"
		for d in "${days[@]}"; do
			for f in "${log_dir}/${main}${d}${ext}" "${log_dir}/${errors}${d}${ext}"; do
				[ -f "${f}" ] && scrub_log "${f}"
			done
		done
		# The topical sub-logs keep the download, server, boot, menu and gesture
		# lines of earlier days; the hotstring and keystats ones can carry typed
		# text and stay.
		for f in "${log_dir}/${main}llm${ext}" "${log_dir}/${main}ollama${ext}" "${log_dir}/${main}boot${ext}" \
			"${log_dir}/${main}menu${ext}" "${log_dir}/${main}gestures${ext}" "${log_dir}/${bootstrap}"; do
			[ -f "${f}" ] && scrub_log "${f}"
		done
		# Crash reports are named, not copied: a dump is read on request.
		step crash_reports sh -c 'ls -la "$1" 2>/dev/null || echo "no crash report"' sh "${log_dir}/${crashes}"
		for d in "${days[@]}"; do
			# The digests read the scrubbed copies, never the raw day log.
			[ -f "${out}/${main}${d}${ext}" ] && day_logs+=("${out}/${main}${d}${ext}")
		done
		if [ "${#day_logs[@]}" -gt 0 ]; then
			step digest_boot grep -hE "Boot complete|Boot completed with|Boot stage completed" "${day_logs[@]}"
			step digest_slow grep -hE "\[HotPath\]|Slow |Main-thread hold of" "${day_logs[@]}"
			step digest_errors grep -hE "\[(ERROR|WARNING)\]" "${day_logs[@]}"
			step digest_snapshot grep -hE "\[Diagnostics\]" "${day_logs[@]}"
			step digest_field_checks grep -hE "check=[a-z_]+ verdict=" "${day_logs[@]}"
			report_field_checks "${out}/digest_field_checks.txt"
			step digest_input grep -hE "grab|uinput|ydotool|device_finder|keymap" "${day_logs[@]}"
		else
			printf '%-28s missing\n' "day_log" >> "${steps}"
		fi
	else
		printf '%-28s missing\n' "logs" >> "${steps}"
		printf '%s\n' "${log_dir}" > "${out}/logs_dir.txt"
		mask_file "${out}/logs_dir.txt"
	fi

	# Which personal triggers share a bundled one, with both sides' flags and no
	# replacement text: the personal file itself never travels.
	if [ -n "${personal:-}" ]; then
		step hotstring_collisions python3 "${REPO_ROOT}/tools/dev/hotstring-collisions.py" \
			"${personal}" "${BUNDLED_HOTSTRINGS}"
	fi
	# The daemon's own journal lines of today at warning or worse: they hold
	# what it printed before its logger opened or after it crashed. Scrubbed
	# like a log, the stdout of a daemon can carry typed text.
	local journal_dir=""
	if command -v journalctl >/dev/null 2>&1 && journal_dir="$(mktemp -d)" \
		&& journalctl --user --since today -p warning -o cat --no-pager -u 'ergopti*' \
			> "${journal_dir}/journal_warnings.txt" 2>/dev/null; then
		scrub_log "${journal_dir}/journal_warnings.txt"
		[ -f "${out}/journal_warnings.txt" ] && mask_file "${out}/journal_warnings.txt"
	else
		printf '%-28s unavailable\n' "journal_warnings" >> "${steps}"
	fi
	[ -z "${journal_dir}" ] || rm -rf "${journal_dir}"
	# Every line the daemon's unit logged since the collector started: what it
	# printed around the field run, its restarts. Scrubbed like a log.
	journal_dir=""
	if command -v journalctl >/dev/null 2>&1 && journal_dir="$(mktemp -d)" \
		&& journalctl --user --since "@${run_started_epoch}" -o short-iso --no-pager -u 'ergopti*' 2>/dev/null \
			| tail -n 2000 > "${journal_dir}/journal_run.txt"; then
		scrub_log "${journal_dir}/journal_run.txt"
		[ -f "${out}/journal_run.txt" ] && mask_file "${out}/journal_run.txt"
	else
		printf '%-28s unavailable\n' "journal_run" >> "${steps}"
	fi
	[ -z "${journal_dir}" ] || rm -rf "${journal_dir}"
	# One verdict per TODO « To confirm on Linux » point, from the field run,
	# the guided and probe steps and steps.txt; printed so the terminal ends on
	# what to tick.
	step todo_summary python3 "${REPO_ROOT}/tools/dev/field-todo-summary.py" --os linux --report "${out}"
	if [ -f "${out}/todo_summary.txt" ]; then
		log "TODO « To confirm on Linux », one verdict per point (todo_summary.md):"
		sed 's/^/[field-report]   /' "${out}/todo_summary.txt"
	fi
	# env.json and the timeline from the fact lines, the step timings, the field
	# run's results and the scrubbed day logs; the analysis reads both.
	field_report_facts linux
	# Last: it also reads the check verdicts the steps above wrote.
	field_report_analyse ${day_logs[@]+"${day_logs[@]}"}
	# After every step that reads the flat names: the synthesis goes to 0_main,
	# the rest to numbered subfolders (field-report-tidy.py). Nothing writes
	# ${steps} after this point.
	python3 "${REPO_ROOT}/tools/dev/field-report-tidy.py" "${out}" \
		&& log "Read first: ${out#"${REPO_ROOT}/"}/0_main/analysis.md (index in 0_main/README.md)." \
		|| log "WARNING: the report folder could not be sorted into subfolders; it stays flat."

	subject="docs(field): Linux field report ${stamp} on ${base}"
	"${interrupted}" && subject="${subject} (interrupted)"
	field_report_commit "${subject}"
}

# Ctrl-C or TERM: the logs are still copied, committed and pushed. A second
# signal during that work is ignored.
on_interrupt() {
	trap '' INT TERM HUP
	interrupted=true
	field_steps_stop_background
	printf '\n'
	log "Interrupted: keeping the evidence collected so far."
	printf '%-28s interrupted\n' "collector" >> "${steps}"
	finalize
	exit 130
}
trap on_interrupt INT TERM HUP

# ===========================================
# ======= 2/ System and session =============
# ===========================================

step versions sh -c 'git rev-parse --short HEAD; uname -srmo; grep -E "^(NAME|VERSION_ID|ID|ID_LIKE)=" /etc/os-release; nproc; grep -E "^(MemTotal|MemAvailable):" /proc/meminfo'
step session sh -c 'printf "XDG_SESSION_TYPE=%s\nXDG_CURRENT_DESKTOP=%s\nDESKTOP_SESSION=%s\nWAYLAND_DISPLAY=%s\nDISPLAY=%s\nLANG=%s\n" "${XDG_SESSION_TYPE:-}" "${XDG_CURRENT_DESKTOP:-}" "${DESKTOP_SESSION:-}" "${WAYLAND_DISPLAY:-}" "${DISPLAY:-}" "${LANG:-}"'
step toolchain sh -c 'luajit -v; luajit -e "require(\"luv\"); print(\"luv ok\")"; luajit -e "require(\"ffi\").load(\"libgtk-3.so.0\"); print(\"gtk3 ok (owned dialog host)\")"; for t in ydotool ydotoold notify-send xdg-open cc; do printf "%s: %s\n" "$t" "$(command -v "$t" || echo missing)"; done'
step keyboard_layout sh -c 'localectl status; command -v setxkbmap >/dev/null && setxkbmap -query; command -v gsettings >/dev/null && gsettings get org.gnome.desktop.input-sources sources; true'
# Input access: the groups, uinput and the evdev nodes the daemon must open.
step input_access sh -c 'id -nG; ls -l /dev/uinput; n=0; r=0; for d in /dev/input/event*; do n=$((n + 1)); [ -r "$d" ] && r=$((r + 1)); done; echo "evdev nodes: $n, readable: $r"; ls /etc/udev/rules.d 2>/dev/null | grep -i ergopti || true'
step units sh -c 'systemctl --user list-units --all --no-pager "ergopti*"'
step processes sh -c 'pgrep -af "ergopti|ydotoold|ollama|llama-server|omlx|local-ai|lm-studio|jan" | grep -v pgrep || true'
# Loopback listeners show which local AI server runs (process names and ports).
step listeners sh -c 'ss -ltnpH 2>/dev/null || true'
step native_backend sh -c 'ls -l "$1"/bin/ 2>&1' sh "${DRIVER_ROOT}"
step runtimes sh -c 'for t in python3 node curl ollama llama-server; do printf "%s: " "$t"; if command -v "$t" >/dev/null; then "$t" --version 2>&1 | head -1; else echo missing; fi; done'
step memory sh -c 'free -m; cat /proc/pressure/memory /proc/pressure/cpu 2>/dev/null; uptime'
# The keyboards the daemon may grab: names and handlers, never what they type.
step input_devices sh -c 'grep -E "^(N: Name|H: Handlers)=" /proc/bus/input/devices'
step autostart sh -c 'systemctl --user list-unit-files --no-pager "ergopti*"; ls "${XDG_CONFIG_HOME:-$HOME/.config}/autostart" 2>/dev/null | grep -i ergopti || echo "no desktop autostart entry"'
step services sh -c 'systemctl --user status --no-pager -n 0 "ergopti*"; systemctl status --no-pager -n 0 "ydotool*" 2>&1 | head -12'
# Whether a proxy or a PAC file is set, never its address.
step proxy sh -c 'for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy all_proxy; do eval "x=\${$v:-}"; [ -n "$x" ] && echo "$v: set" || echo "$v: unset"; done; if command -v gsettings >/dev/null; then echo "gnome mode: $(gsettings get org.gnome.system.proxy mode 2>&1)"; [ "$(gsettings get org.gnome.system.proxy autoconfig-url 2>/dev/null)" = "'"''"'" ] && echo "gnome autoconfig-url: unset" || echo "gnome autoconfig-url: set"; fi'
# Core dumps of today of the daemon's processes: named, not copied.
step crash_dumps sh -c 'command -v coredumpctl >/dev/null || { echo "no coredumpctl"; exit 0; }; coredumpctl list --since today --no-pager 2>&1 | grep -iE "luajit|ergopti|ydotool|ollama|COMMAND|No coredumps" || echo "no core dump today"'
# The checks that need no person (tools/dev/linux-field-shell-checks.sh).
step collector_checks field_linux_checks "${REPO_ROOT}"
# Every Ergopti daemon and helper now, before the run, every
# FIELD_SAMPLER_SECONDS during it and after it: two daemons or a restart are
# on record; then the other remappers, the access the daemon needs and the
# machine.
bstep instances_start 30 field_linux_instances start
warn_multiple_drivers instances_start
bstep remappers 60 field_linux_remappers
bstep permissions 30 field_linux_permissions
bstep environment 30 field_linux_environment
bstep service_state 30 field_linux_service_state
bstep app_folders 60 field_linux_app_folders
# The daemon's Debug field checks, run with no window (tools/dev/linux-field-run.sh).
# The composer check needs Ergopti's Python; running the collector is the consent.
field_linux_ensure_python "${REPO_ROOT}" 2>&1 | tee "${out}/field_python.txt" | sed 's/^/[field-report] /'
printf '%-28s exit=%s\n' "field_python" "${PIPESTATUS[0]}" >> "${steps}"
bstep instances_before_run 30 field_linux_instances before_run
warn_multiple_drivers instances_before_run
field_sampler_start field_linux_instances
log "▶ field run: asking the daemon to run its field checks (each verdict prints here)…"
phase_started="$(date +%s)"
field_step_ticker_start field_run "${out}/field_run.txt" "${phase_started}"
field_linux_run "${REPO_ROOT}" "${out}" 2>&1 | tee "${out}/field_run.txt" | sed 's/^/[field-report] /'
phase_status="${PIPESTATUS[0]}"
field_step_ticker_stop
printf '%-28s exit=%s\n' "field_run" "${phase_status}" >> "${steps}"
field_sampler_stop
field_phase_done field_run "${phase_started}" "${phase_status}" 0
log "  field run ended (exit ${phase_status}, $(( $(date +%s) - phase_started )) s)."
bstep instances_end 30 field_linux_instances end
warn_multiple_drivers instances_end
FIELD_STEP_HINT="keep your hands off the keyboard and mouse for ${FIELD_IDLE_SECONDS} s (idle CPU)"
bstep idle_cpu $((FIELD_IDLE_SECONDS + 30)) field_linux_idle_cpu
FIELD_STEP_HINT=""
# The collector's own steps (static/ergopti_plus/linux/diagnostics/data/field_guided_steps.json):
# probes read the session once (uinput, evdev, autostart, polkit, the focus
# reporter), guided steps print a gesture and count what it left in today's
# day log or the Metrics database, attested steps take y, n or s. Only counts
# and closed codes reach field_guided/; the raw log is read here, never copied.
guided_sources=()
if layout="$(driver_log_layout 2>/dev/null)"; then
	{ read -r g_log_dir; read -r g_main; read -r _; read -r g_ext; read -r _; read -r _; read -r _; read -r g_metrics; } <<< "${layout}"
	guided_sources=(--log "${g_log_dir}/${g_main}$(date +%Y-%m-%d)${g_ext}" --metrics "${g_metrics}")
fi
log "▶ guided steps: each prints its gesture here and waits for it."
phase_started="$(date +%s)"
FIELD_STEP_HINT="the gesture or the y, n or s answer the guided step above asks for"
field_step_ticker_start field_guided "${out}/field_guided.txt" "${phase_started}"
python3 "${REPO_ROOT}/tools/dev/field-guided.py" --steps "${DRIVER_ROOT}/diagnostics/data/field_guided_steps.json" \
	--out "${out}" ${guided_sources[@]+"${guided_sources[@]}"} 2>&1 | tee "${out}/field_guided.txt"
phase_status="${PIPESTATUS[0]}"
field_step_ticker_stop
FIELD_STEP_HINT=""
printf '%-28s exit=%s\n' "field_guided" "${phase_status}" >> "${steps}"
field_phase_done field_guided "${phase_started}" "${phase_status}" 0
log "  guided steps ended (exit ${phase_status}, $(( $(date +%s) - phase_started )) s)."

# ===========================================
# ======= 3/ Logs, commit and push ==========
# ===========================================

finalize
