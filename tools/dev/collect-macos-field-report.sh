#!/usr/bin/env bash
# tools/dev/collect-macos-field-report.sh

# ==============================================================================
# MODULE: macOS field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Mac: it updates the field
# branch from its base (dev unless it was derived from another branch), gathers the evidence the coordinator reads (system and
# toolchain facts, the field run of the developer app, the input-source probe,
# today's ErgoptiPlus logs, their digest and their analysis), stores it under
# docs/field-reports/, then commits and pushes the branch. The logs are
# gitignored, so they are added with `git add -f`; the logger already masks
# secrets, the home folder, e-mail addresses and personal names, and the
# summary lists every file it adds.
#
# The field run: the collector opens the developer app of this clone when it
# is not running (tools/dev/run-macos-dev-app.sh, which builds it first when
# no developer app exists), asks it through the clone folder it declares to run
# every Debug field check, the diagnostics collection and the Ollama and MLX
# download flows (infra/field_run.lua; contract in
# static/ergopti_plus/macos/data/field_run.json), waits for its done marker
# until the request's own deadline plus a grace, and copies its results.
#
# The analysis: tools/dev/field-log-analyse.py, the analyser the three
# collectors share, reads the scrubbed day logs and writes analysis.md and
# analysis.json at the top of the report (errors grouped by template, every
# measured duration against the budget its code declares, lifecycle events,
# check verdicts, what to fix first) and prints its summary.
#
# USAGE (from any branch: outside a field/ branch the collector switches to
# field/mac-<today>-<branch>, derived from that branch and created when
# missing; base.txt in the report names the base and the commit):
#   bash tools/dev/collect-macos-field-report.sh            update, collect, commit, push
#   bash tools/dev/collect-macos-field-report.sh --no-push  same, without the push
#   bash tools/dev/collect-macos-field-report.sh --installed  the complete run,
#     Karabiner included, on the signed dev prerelease instead of the developer
#     app: installs or updates it from GitHub, verified
#     (tools/dev/install-macos-dev-prerelease.sh), reopens it with this clone as
#     its field-run root, and runs every step in it, the owned runtime's first
#     install included (field_owned_install: the macOS administrator prompt and
#     the driver approval are the only human steps, and the terminal says so)
#
# By default the field run tests the branch itself: the developer app of this
# clone, which any tester builds, with no release and no certificate. The
# owned Karabiner runtime installs only under the stable certificate the CI
# signs with, so the steps field_run.json marks signed_app are left out there
# and run only with --installed (docs/tooling/next-release-handoff.md, WP9).
#
# Each step records its exit status in steps.txt; a failed step never hides
# the others, and the summary names it. Ctrl-C or a TERM never loses the
# evidence: the collector still copies the results and logs that exist, then
# commits and pushes them, marked interrupted.
# ==============================================================================

set -uo pipefail

# Command substitution removes trailing LF bytes, even when they belong to a
# directory name. Capture a sentinel and remove only that final byte afterward.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "${PWD}")"
REPO_ROOT="${REPO_ROOT%.}"
# The collector keeps going after a failed step, but never without the shared
# identifiers: a missing file stops it here.
set -e
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
# shellcheck source=macos-field-shell-checks.sh
. "$REPO_ROOT/tools/dev/macos-field-shell-checks.sh"
# shellcheck source=field-report-git.sh
. "$REPO_ROOT/tools/dev/field-report-git.sh"
set +e
# The folders and file names come from their shared declarations, never from
# a copy here (tools/dev/field-report-paths.py). The topical logs that help a
# diagnosis; the hotstring and keystroke logs can carry typed text and stay.
FIELD_TOPICAL_LOGS="llm ollama mlx boot karabiner menu"
# shellcheck disable=SC2086 # one word per log name
field_paths="$(python3 "${REPO_ROOT}/tools/dev/field-report-paths.py" "${REPO_ROOT}/static/ergopti_plus/_shared" ${FIELD_TOPICAL_LOGS})" \
	|| { printf '[field-report] ERROR: cannot resolve the driver folders.\n' >&2; exit 1; }
eval "${field_paths}"
BUNDLED_HOTSTRINGS="static/ergopti_plus/_shared/modules/hotstrings"
FIELD_RUN_SPEC="static/ergopti_plus/macos/data/field_run.json"
# How long the collector keeps waiting for done after the request's own
# deadline (the declared default, which covers every step at its bound): the
# app needs a moment to settle the last step, run the guard and write done.
FIELD_RUN_GRACE_SECONDS=120
# How many times a run a reload interrupted is requested again.
FIELD_RUN_RELOAD_RETRIES=2
# How long the developer app may take to publish its readiness, and then to
# accept the request it was sent. Right after a reboot the 12:02 run of
# 2026-10-28 saw the ready app hold its main thread 138 s (keystats ledger
# replay) before it took the request, past the former 60 s. The field run
# contract test shortens the budgets and the poll through the *_OVERRIDE
# variables, so a case that waits on purpose does not wait minutes. A new
# install asks for Accessibility first and the app's boot waits for it up to
# M.DEADLINE_SECONDS of infra/accessibility_wait.lua (600 s): the readiness
# budget covers that wait and two minutes of boot.
FIELD_RUN_ACCESSIBILITY_WAIT_SECONDS="$(sed -n 's/^M\.DEADLINE_SECONDS = \([0-9][0-9]*\)$/\1/p' \
	"${REPO_ROOT}/static/ergopti_plus/macos/infra/accessibility_wait.lua")"
[ -n "${FIELD_RUN_ACCESSIBILITY_WAIT_SECONDS}" ] \
	|| { printf '[field-report] ERROR: infra/accessibility_wait.lua declares no DEADLINE_SECONDS.\n' >&2; exit 1; }
FIELD_RUN_READY_SECONDS="${FIELD_RUN_READY_SECONDS_OVERRIDE:-$((FIELD_RUN_ACCESSIBILITY_WAIT_SECONDS + 120))}"
FIELD_RUN_ACCEPT_SECONDS="${FIELD_RUN_ACCEPT_SECONDS_OVERRIDE:-300}"
FIELD_RUN_POLL_SECONDS="${FIELD_RUN_POLL_SECONDS_OVERRIDE:-5}"

fail() { printf '[field-report] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[field-report] %s\n' "$*"; }

push=true
installed=false
for argument in "$@"; do
	case "${argument}" in
		--no-push) push=false ;;
		--installed) installed=true ;;
		*) fail "Expected no argument, --no-push or --installed." ;;
	esac
done

[ "$(uname -s)" = "Darwin" ] || fail "This collector runs on macOS only."
cd "${REPO_ROOT}" || fail "Cannot enter the repository root."
git rev-parse --git-dir >/dev/null 2>&1 || fail "Not inside the Ergopti clone."

# From dev, main or any other branch (or a detached commit) the report goes to
# a field branch derived from it (tools/dev/field-report-git.sh), so a
# maintainer only has to run this script.
field_report_enter_branch mac

# ===========================================
# ======= 1/ Update from the base ===========
# ===========================================

field_report_update_from_base "${REPO_ROOT}/tools/dev/collect-macos-field-report.sh" "$@"
field_report_open_folder mac
# The crash report summaries keep the reports written from here on.
run_started_epoch="$(date +%s)"
# Set by the INT/TERM trap; the remaining evidence is still collected.
interrupted=false
finalized=false

# Runs one named step, captures its output into a file and records its status.
step() {
	local name="$1"; shift
	local file="${out}/${name}.txt"
	"$@" > "${file}" 2>&1
	local status=$?
	printf '%-28s exit=%s\n' "${name}" "${status}" >> "${steps}"
	[ "${status}" -eq 0 ] || log "step '${name}' exited ${status} (kept in ${file})"
	return 0
}

# Reads one value of the field run declaration.
spec_value() {
	plutil -extract "$1" raw -o - "${REPO_ROOT}/${FIELD_RUN_SPEC}"
}

# The field run's paths, resolved in the main shell: the interrupt trap copies
# the partial results from them, and run_field_run runs in a pipeline subshell.
request_id="mac-${stamp}"
run_folder=""
results_dir=""
if folder="$(spec_value folder)" && results_name="$(spec_value files.results)"; then
	run_folder="${REPO_ROOT}/${folder}"
	results_dir="${run_folder}/${results_name}/${request_id}"
fi

# Copies the results the app wrote so far, once; a later copy never replaces it.
copy_field_run_results() {
	[ -n "${results_dir}" ] && [ -d "${results_dir}" ] || return 1
	[ -e "${out}/field_run" ] && return 0
	cp -R "${results_dir}" "${out}/field_run"
}

# Copies one log into the report without the user's typed text.
scrub_log() {
	local source="$1" name
	name="$(basename "${source}")"
	if python3 "${REPO_ROOT}/tools/dev/field-log-scrub.py" "${source}" "${out}/${name}" \
		"${REPO_ROOT}/${BUNDLED_HOTSTRINGS}"; then
		printf '%-28s copied (scrubbed)\n' "${name}" >> "${steps}"
	else
		# Never fall back to the raw log: it would publish the typed text.
		rm -f "${out}/${name}"
		printf '%-28s scrub failed, not copied\n' "${name}" >> "${steps}"
	fi
}

# Copies the logs, commits and pushes, once: from the normal end and from the
# INT/TERM trap, so an interrupted run still leaves its evidence on the branch.
finalize() {
	"${finalized}" && return 0
	finalized=true
	local start_day today d f subject
	# Resolved again: the app's first boot can write LogsDirPath during the run,
	# and the folders read at start then pointed at yesterday's logs (field
	# report 2026-11-05). Which one is said without the path, which names the home.
	# shellcheck disable=SC2086 # one word per log name
	field_paths="$(python3 "${REPO_ROOT}/tools/dev/field-report-paths.py" "${REPO_ROOT}/static/ergopti_plus/_shared" ${FIELD_TOPICAL_LOGS})" \
		&& eval "${field_paths}"
	if [ "${LOG_DIR}" = "${LOG_DEFAULT_DIR}" ]; then
		printf '%-28s default folder\n' "log_folder" >> "${steps}"
	else
		printf '%-28s LogsDirPath\n' "log_folder" >> "${steps}"
	fi
	local days=() day_logs=()
	# A run that crosses midnight spans two day logs: keep both, oldest first.
	start_day="${stamp%%_*}"
	today="$(date +%Y-%m-%d)"
	days=("${start_day}")
	[ "${today}" = "${start_day}" ] || days+=("${today}")
	if [ -d "${LOG_DIR}" ]; then
		# The branch is pushed to a public repository and the logs carry typed
		# text (hotstring expansions, AI prompts): only scrubbed copies leave
		# the Mac, and the digests below read those copies.
		for d in "${days[@]}"; do
			for f in "${LOG_DIR}/${LOG_UNIFIED_PREFIX}${d}${LOG_EXTENSION}" "${LOG_DIR}/${LOG_ERRORS_PREFIX}${d}${LOG_EXTENSION}"; do
				[ -f "${f}" ] && scrub_log "${f}"
			done
		done
		for f in ${LOG_TOPICAL}; do
			f="${LOG_DIR}/${f}"
			[ -f "${f}" ] && scrub_log "${f}"
		done
		for d in "${days[@]}"; do
			f="${out}/${LOG_UNIFIED_PREFIX}${d}${LOG_EXTENSION}"
			[ -f "${f}" ] && day_logs+=("${f}")
		done
		if [ "${#day_logs[@]}" -gt 0 ]; then
			step digest_boot grep -hE "Boot complete|Boot CPU|Boot stage completed|held the main thread" "${day_logs[@]}"
			step digest_slow grep -hE "\[HotPath\]|Slow |Main-thread hold of" "${day_logs[@]}"
			step digest_errors grep -hE "\[(ERROR|WARNING)\]" "${day_logs[@]}"
			step digest_input grep -hE "key_event_health|karabiner.lease|guardian" "${day_logs[@]}"
			step digest_hotstrings grep -hiE "expand|hotstring|terminator|rescan|priority" "${day_logs[@]}"
		fi
	else
		printf '%-28s missing\n' "logs" >> "${steps}"
	fi
	# The launcher's own log and fatal report live in the default folder even
	# when LogsDirPath moves the others: looking for them in LOG_DIR skipped
	# them silently, so the reload lost on 2026-10-30 21:06 left no trace of
	# how the launcher saw its runtime end.
	for f in "${LOG_LAUNCHER}" "${LOG_FATAL_REPORT}"; do
		if [ -f "${LOG_DEFAULT_DIR}/${f}" ]; then
			scrub_log "${LOG_DEFAULT_DIR}/${f}"
		else
			printf '%-28s missing\n' "${f}" >> "${steps}"
		fi
	done
	# The last controlled reload's stage trail (adapters/reload_breadcrumb.lua):
	# stage names and monotonic times only, so it travels unscrubbed. Its last
	# line names the stage a lost reload stopped in; `boot` proves one followed.
	if [ -f "${RELOAD_BREADCRUMB}" ]; then
		cp "${RELOAD_BREADCRUMB}" "${out}/reload_breadcrumb.txt"
	else
		printf '%-28s missing\n' "reload_breadcrumb" >> "${steps}"
	fi
	# Which personal triggers share a bundled one, with both sides' flags and no
	# replacement text: the personal file itself never travels.
	step hotstring_collisions python3 "${REPO_ROOT}/tools/dev/hotstring-collisions.py" \
		"${PERSONAL_HOTSTRINGS}" "${REPO_ROOT}/${BUNDLED_HOTSTRINGS}"
	# Last: it also reads the check verdicts the steps above wrote.
	field_report_analyse ${day_logs[@]+"${day_logs[@]}"}

	subject="docs(field): macOS field report ${stamp} on ${base}"
	"${interrupted}" && subject="${subject} (interrupted)"
	field_report_commit "${subject}"
}

# Ctrl-C or TERM: the field run's partial results and today's logs are still
# copied, committed and pushed. A second signal during that work is ignored.
on_interrupt() {
	trap '' INT TERM HUP
	interrupted=true
	printf '\n'
	log "Interrupted: keeping the results and logs collected so far."
	printf '%-28s interrupted\n' "collector" >> "${steps}"
	copy_field_run_results || true
	finalize
	exit 130
}
trap on_interrupt INT TERM HUP

# ===========================================
# ======= 2/ System and toolchain ===========
# ===========================================

step versions sh -c 'git rev-parse --short HEAD; sw_vers; uname -m; sysctl -n hw.ncpu hw.memsize'
# Go builds the developer app's own Ollama (stage-macos-dev-ollama-catalogue.py).
step toolchain sh -c 'xcode-select -p; swift --version; swift build --version; which -a swift; go version || echo "no go on PATH"'
step karabiner sh -c '"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli" --version'
# The app's field check only sees codesign's exit code; keep both tools' own
# reasons so a failed signature check names its cause.
step karabiner_signature sh -c 'codesign --verify --deep --strict --verbose=4 /Applications/Karabiner-Elements.app; echo "codesign exit=$?"; spctl -a -vv /Applications/Karabiner-Elements.app; echo "spctl exit=$?"'
step memory sh -c 'memory_pressure | tail -1; vm_stat | head -5'
# Only a Mac compiles AppleScript, so a .applescript edited elsewhere leaves
# its .scpt stale (the Encryptor comment of the keystats rename). The rebuilt
# files are committed on the field branch, apart from the report, so the push
# carries them and the next run starts from a clean tree; cherry-pick that
# commit to the base.
step scpt_recompile python3 "${REPO_ROOT}/tools/dev/recompile-applescripts.py" "${REPO_ROOT}"
if ! git -C "${REPO_ROOT}" diff --quiet -- '*.scpt'; then
	(cd "${REPO_ROOT}" && git add -u -- '*.scpt' \
		&& git commit -q -m "chore(macos): recompile the AppleScript sources the field run found stale" -- '*.scpt') \
		&& log "Recompiled AppleScript committed on ${branch}; cherry-pick that commit to ${base}." \
		|| log "WARNING: the recompiled AppleScript could not be committed; see ${out}/scpt_recompile.txt."
fi
# The process names of _shared/modules/llm/local_servers.json (discovery) too,
# so a report shows which local API server runs
step processes sh -c 'pgrep -ilf "ErgoptiPlus|Hammerspoon|karabiner|ollama|omlx|llama-server|local-ai|LM Studio|llmster|Jan" || true'
step launchd sh -c 'launchctl list | grep -iE "ergopti|pqrs" || true'
# Unfiltered: a server renamed by setproctitle (oMLX's Python shows as
# "Python" to lsof) or listening on a port set by the user must still appear.
# It holds only process names, pids and loopback ports.
step listeners sh -c 'lsof -nP -iTCP -sTCP:LISTEN || true'
step input_sources sh -c 'defaults read com.apple.HIToolbox AppleEnabledInputSources; defaults read com.apple.HIToolbox AppleSelectedInputSources'
step user_layouts sh -c 'ls -la "${HOME}/Library/Keyboard Layouts" 2>&1'
# The Trackpad and Dock gesture keys the gesture conflict read uses
# (modules/gestures/conflicts.lua), read only: a slot macOS still takes after
# "Restore recommended" reads against them. The Dock domain also lists the
# user's applications, so only its gesture switches are read.
step trackpad_gestures sh -c '
	for domain in com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad; do
		echo "== $domain"; defaults read "$domain" 2>&1
	done
	echo "== -currentHost -globalDomain (gesture keys)"
	defaults -currentHost read -globalDomain 2>&1 | grep -iE "trackpad|gesture" || echo "no gesture key"
	echo "== com.apple.dock (gesture switches)"
	for key in showMissionControlGestureEnabled showAppExposeGestureEnabled showDesktopGestureEnabled showLaunchpadGestureEnabled; do
		printf "%s: " "$key"; defaults read com.apple.dock "$key" 2>&1
	done'
# The day's sleeps and wakes: a key stuck across a sleep or a lease lost at
# wake reads against them.
step power sh -c 'uptime; pmset -g batt | head -2; pmset -g log | grep -E " (Sleep|Wake|DarkWake) " | grep "$(date +%Y-%m-%d)" | tail -40'
# Whether a proxy or a PAC file is set, never its address.
step proxy sh -c 'scutil --proxy | sed -nE "s/^ *([A-Za-z]+Enable) : ([0-9]+)$/\1: \2/p; s/^ *([A-Za-z]*(Proxy|URLString)) : .+$/\1: set/p"; for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy; do eval "x=\${$v:-}"; [ -n "$x" ] && echo "$v: set" || echo "$v: unset"; done'
# Crash reports of the day of the processes Ergopti runs or drives: named, not copied.
step crash_reports sh -c 'names="$(find "${HOME}/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 2 -type f -mtime -1 2>/dev/null | sed "s#.*/##" | grep -iE "^(ErgoptiPlus|Hammerspoon|karabiner|ollama|omlx|python|uv)[-_. ]")"; [ -n "$names" ] && printf "%s\n" "$names" || echo "no crash report today"'
step launch_agents sh -c 'ls "${HOME}/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null | grep -iE "ergopti|pqrs|karabiner|ollama|hammerspoon" || echo "none"'
step disk sh -c 'df -h / "${TMPDIR:-/tmp}" | sed "s#${HOME}#~#g"'
# Ergopti's own Karabiner runtime (ADR 011) without the app: both launchd jobs,
# the installed files, the DriverKit approval, the verified download and the
# signing authority of the installed app (the install needs a certificate).
step owned_runtime sh -c '
	for label in "$1" "$2"; do launchctl print "system/$label" >/dev/null 2>&1; echo "$label: launchctl print exit=$?"; done
	for path in "/Library/Application Support/ErgoptiPlus/Runtime" "/Library/LaunchDaemons/$1.plist" "/Library/LaunchDaemons/$2.plist"; do
		[ -e "$path" ] && echo "present: $path" || echo "absent: $path"
	done
	systemextensionsctl list 2>&1 | grep -i "Karabiner-DriverKit-VirtualHIDDevice" || echo "no pqrs driver extension listed"
	ls "${HOME}/Library/Application Support/Ergopti/RemapRuntime"/*/receipt 2>/dev/null | sed "s#${HOME}#~#" || echo "no verified runtime download"
	codesign -dv --verbose=2 "/Applications/$3" 2>&1 | grep -E "^(Authority|TeamIdentifier|Signature)=" || echo "no installed $3"
	# The Console is the launcher'"'"'s child (never disclaimed), so macOS files its
	# Input Monitoring under the app: its parent must be the launcher.
	console="$(pgrep -f "ErgoptiPlus-Remap-Console.app/Contents/MacOS/" | head -1)"
	if [ -n "$console" ]; then
		parent="$(ps -o ppid= -p "$console" | tr -d " ")"
		echo "console parent: $(ps -o comm= -p "$parent" | sed "s#.*/##")"
	else
		echo "console parent: no owned Console running"
	fi
' sh "${ERGOPTI_SERVICE_LABEL_MACOS_CORE}" "${ERGOPTI_SERVICE_LABEL_MACOS_VIRTUAL_HID}" "${ERGOPTI_APP_BUNDLE}"

# ===========================================
# ======= 3/ Field run in the app ===========
# ===========================================

# Prints the pid a readiness file names when that process is alive.
ready_pid() {
	local pid
	[ -f "${ready_file}" ] || return 1
	pid="$(plutil -extract pid raw -o - "${ready_file}" 2>/dev/null)" || return 1
	case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "${pid}" 2>/dev/null || return 1
	printf '%s\n' "${pid}"
}

# Maps a step verdict to the mark the maintainer scans the output for; the
# verdict word stays after it so the logs remain searchable.
verdict_mark() {
	case "$1" in
		pass) printf '✅' ;;
		fail) printf '❌' ;;
		skip) printf '⏭️' ;;
		needs_typing) printf '⌨️' ;;
		*) printf '⚠️' ;;
	esac
}

# Prints each step result once, as it appears, and counts the passes and fails.
report_new_results() {
	local file name verdict
	for file in "${results_dir}"/[0-9][0-9]_*.json; do
		[ -f "${file}" ] || continue
		name="$(basename "${file}" .json)"
		case " ${seen_results} " in *" ${name} "*) continue ;; esac
		seen_results="${seen_results} ${name}"
		verdict="$(plutil -extract verdict raw -o - "${file}" 2>/dev/null || printf 'unreadable')"
		case "${verdict}" in
			pass) passed_results=$((passed_results + 1)) ;;
			fail) failed_results=$((failed_results + 1)) ;;
			*) other_results=$((other_results + 1)) ;;
		esac
		log "  $(verdict_mark "${verdict}") field run ${name}: ${verdict}"
	done
}

# Waits until the app accepts the request, across a reload or a restart of the
# developer app: a readiness that goes away gets the readiness budget again, a
# new readiness the acceptance budget again, both within their sum since the
# request. A request the app consumed is its run: the caller waits for done. A
# request still unconsumed at the end is withdrawn, so no run starts after the
# collector gave up (and loses its results).
# Returns 0 once accepted, consumed, refused or done; 1 when it gave up.
wait_for_acceptance() {
	local now current app_pid="${pid}" waited_from="${sent_at}" budget taken_at=""
	while [ ! -f "${results_dir}/${accepted_name}" ]; do
		[ -f "${run_folder}/${refused_name}" ] && return 0
		[ -f "${results_dir}/${done_name}" ] && return 0
		now="$(date +%s)"
		# An app that took the request accepts it at once; one that took it and
		# never accepts it is not running the field run.
		if [ ! -f "${run_folder}/${request_name}" ]; then
			taken_at="${taken_at:-${now}}"
			if [ $((now - taken_at)) -ge "${FIELD_RUN_ACCEPT_SECONDS}" ]; then
				log "The request was taken but not accepted within ${FIELD_RUN_ACCEPT_SECONDS} s; no developer app is running the field run."
				return 1
			fi
			sleep "${FIELD_RUN_POLL_SECONDS}"
			continue
		fi
		if current="$(ready_pid)"; then
			if [ "${current}" != "${app_pid}" ]; then
				log "The developer app published its readiness again (pid ${current}); waiting for it to accept the request."
				app_pid="${current}"
				waited_from="${now}"
			fi
		elif [ -n "${app_pid}" ]; then
			log "The developer app (pid ${app_pid}) is reloading or gone; waiting for its readiness again."
			app_pid=""
			waited_from="${now}"
		fi
		budget="${FIELD_RUN_ACCEPT_SECONDS}"
		[ -n "${app_pid}" ] || budget="${FIELD_RUN_READY_SECONDS}"
		if [ $((now - waited_from)) -ge "${budget}" ] \
			|| [ $((now - sent_at)) -ge $((FIELD_RUN_READY_SECONDS + FIELD_RUN_ACCEPT_SECONDS)) ]; then
			if rm "${run_folder}/${request_name}" 2>/dev/null; then
				log "The app did not accept the request within $((now - sent_at)) s; request withdrawn so no run starts without the collector."
				return 1
			fi
			# The app took it between the check and the withdrawal: wait for its
			# acceptance like any taken request.
			continue
		fi
		sleep "${FIELD_RUN_POLL_SECONDS}"
	done
	return 0
}

# Opens the developer app, sends the request, waits for done and copies it.
run_field_run() {
	local request_name accepted_name done_name refused_name deadline_seconds
	[ -n "${run_folder}" ] || { log "Cannot read ${FIELD_RUN_SPEC}."; return 1; }
	ready_file="${run_folder}/$(spec_value files.ready)"
	request_name="$(spec_value files.request)"
	refused_name="$(spec_value files.refused)"
	accepted_name="$(spec_value files.accepted)"
	done_name="$(spec_value files.done)"
	deadline_seconds="$(spec_value deadline_seconds.default)"
	seen_results=""
	passed_results=0
	failed_results=0
	other_results=0
	local started_at now pid
	started_at="$(date +%s)"

	# A developer app built from the current launcher is reused when it is ready.
	# A launcher, native helper or build recipe newer than the built binary means
	# the running app is stale: the runner stops it (and any installed
	# ErgoptiPlus or kept-alive guardian) and rebuilds, even when it answers. A
	# Lua-only change needs no rebuild: the developer app reloads it.
	local app_binary="${REPO_ROOT}/build/macos/${ERGOPTI_APP_BUNDLE}/Contents/MacOS/${ERGOPTI_APP_NAME}"
	local stale=""
	if [ "${installed}" = true ]; then
		rm -f "${ready_file}" || { log "Cannot remove the previous readiness."; return 1; }
		bash "${REPO_ROOT}/tools/dev/install-macos-dev-prerelease.sh" \
			|| { log "The signed dev prerelease could not be installed and opened (reason above)."; return 1; }
		log "Three steps may need you: if System Settings opens Accessibility, switch on the entry Ergopti's dialog"
		log "names (never add one with +); type your password if macOS asks for it (Ergopti installs its own"
		log "Karabiner runtime); and if System Settings opens Login Items & Extensions, switch on the Karabiner driver."
		log "Nothing else needs a click; the run waits for all three."
	elif [ ! -x "${app_binary}" ]; then
		stale="no developer app is built"
	else
		stale="$(find "${REPO_ROOT}/static/ergopti_plus/macos/launcher" "${REPO_ROOT}/tools/build" \
			-type f -newer "${app_binary}" -print -quit 2>/dev/null)"
	fi
	# A readiness left by an app the runner is about to stop would send the
	# request to that app: only the readiness of the app opened here counts.
	if [ "${installed}" = true ]; then
		: # Opened above with its field-run root; its readiness is the one to wait for.
	elif [ -n "${stale}" ] || ! ready_pid >/dev/null; then
		rm -f "${ready_file}" || { log "Cannot remove the previous readiness."; return 1; }
	fi
	if [ "${installed}" = true ]; then
		:
	elif [ -n "${stale}" ]; then
		log "Building and opening the developer app (${stale#"${REPO_ROOT}/"} is newer than the build; a few minutes)..."
		bash "${REPO_ROOT}/tools/dev/run-macos-dev-app.sh" || { log "The developer app could not be built."; return 1; }
	elif ! ready_pid >/dev/null; then
		log "Opening the developer app..."
		bash "${REPO_ROOT}/tools/dev/run-macos-dev-app.sh" --open-only \
			|| { log "The developer app could not be opened."; return 1; }
	else
		log "Reusing the running developer app: it was built from the current launcher."
		# The runner stages the managed Ollama only when it opens the app. The
		# installer reads the catalogue at each install, so staging it here gives
		# the ollama_runtime step the build of this clone's current sources.
		python3 "${REPO_ROOT}/tools/dev/stage-macos-dev-ollama-catalogue.py" \
			|| log "WARNING: the managed Ollama was not built from this clone's pinned sources (reason above); the ollama_runtime step will fail."
	fi

	# The readiness budget counts from the app's opening, not from before the
	# install: the download and the administrator password once used all 240 s
	# while the new app became ready 2 s after it opened (field report 2026-11-05).
	started_at="$(date +%s)"
	# A reload (from the menu, or one the run triggers) closes the run as
	# interrupted before any step result; the run is requested again, up to
	# FIELD_RUN_RELOAD_RETRIES times, so one reload does not cost the report.
	local attempt=1 cause
	while :; do
		run_field_attempt
		case $? in
			0) return 0 ;;
			2) ;;
			*) return 1 ;;
		esac
		cause="$(plutil -extract cause.kind raw -o - "${results_dir}/${done_name}" 2>/dev/null || true)"
		if [ "${cause}" != reload ] || [ "${attempt}" -gt "${FIELD_RUN_RELOAD_RETRIES}" ]; then
			log "The field run was cut short in the app (see its log); the results so far are kept."
			return 1
		fi
		# The attempt's copy moves aside so the next attempt's results are the report's
		mv "${out}/field_run" "${out}/field_run_attempt_${attempt}" 2>/dev/null || true
		attempt=$((attempt + 1))
		started_at="$(date +%s)"
		request_id="mac-${stamp}-r${attempt}"
		results_dir="${run_folder}/$(spec_value files.results)/${request_id}"
		seen_results="" passed_results=0 failed_results=0 other_results=0
		log "Ergopti reloaded during the run; requesting the field run again (attempt ${attempt})."
	done
}

# One request of the field run: readiness, request, acceptance, done.
# Returns 0 when done, 2 when the app closed it as interrupted, 1 otherwise.
run_field_attempt() {
	local now pid
	log "Waiting for the developer app to publish its readiness..."
	while ! pid="$(ready_pid)"; do
		now="$(date +%s)"
		if [ $((now - started_at)) -ge "${FIELD_RUN_READY_SECONDS}" ]; then
			log "No ready developer app after ${FIELD_RUN_READY_SECONDS} s. If an installed ${ERGOPTI_APP_NAME} is running, quit it and run this again."
			return 1
		fi
		sleep "${FIELD_RUN_POLL_SECONDS}"
	done
	# The developer app is signed ad hoc: the owned runtime refuses to install
	# under it, so the steps that need the signed app are left to --installed.
	local steps_json='["all"]'
	if [ "${installed}" != true ]; then
		steps_json="$(python3 -c 'import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
print(json.dumps([s["id"] for s in steps if not s.get("signed_app")]))' "${REPO_ROOT}/${FIELD_RUN_SPEC}")" \
			|| { log "Cannot read the steps of ${FIELD_RUN_SPEC}."; return 1; }
		log "Developer app of this branch: the Karabiner runtime install steps are left out; --installed runs them on the signed dev prerelease."
	fi
	log "Developer app ready (pid ${pid}); requesting the field run within ${deadline_seconds} s."
	log "The run is working now: do not reload or quit Ergopti; each step prints its verdict here."

	rm -f "${run_folder}/${refused_name}"
	printf '{"schema":1,"request_id":"%s","steps":%s,"deadline_seconds":%s}\n' \
		"${request_id}" "${steps_json}" "${deadline_seconds}" > "${run_folder}/.${request_name}.tmp" \
		|| { log "Cannot write the field run request."; return 1; }
	mv -f "${run_folder}/.${request_name}.tmp" "${run_folder}/${request_name}" \
		|| { log "Cannot publish the field run request."; return 1; }
	local sent_at last_note gone_since=""
	sent_at="$(date +%s)"
	last_note="${sent_at}"
	wait_for_acceptance || return 1

	while [ ! -f "${results_dir}/${done_name}" ]; do
		if [ -f "${run_folder}/${refused_name}" ]; then
			log "The app refused the request: $(cat "${run_folder}/${refused_name}")"
			cp "${run_folder}/${refused_name}" "${out}/field_run_refused.json"
			return 1
		fi
		now="$(date +%s)"
		if [ $((now - sent_at)) -ge $((deadline_seconds + FIELD_RUN_GRACE_SECONDS)) ]; then
			log "No done marker $((deadline_seconds + FIELD_RUN_GRACE_SECONDS)) s after the request; keeping the partial results."
			report_new_results
			copy_field_run_results
			return 1
		fi
		# An app that is gone writes no done: wait for it to come back (a reload)
		# for as long as a first readiness, then keep the partial results.
		if ready_pid >/dev/null; then
			gone_since=""
		else
			gone_since="${gone_since:-${now}}"
			if [ $((now - gone_since)) -ge "${FIELD_RUN_READY_SECONDS}" ]; then
				log "The developer app has been gone for ${FIELD_RUN_READY_SECONDS} s; keeping the partial results."
				report_new_results
				copy_field_run_results
				return 1
			fi
		fi
		report_new_results
		# A download can stay silent for minutes: say the run is still alive
		if [ $((now - last_note)) -ge 60 ]; then
			last_note="${now}"
			log "  field run still running, $((now - sent_at)) s since the request..."
		fi
		sleep "${FIELD_RUN_POLL_SECONDS}"
	done
	report_new_results
	copy_field_run_results || { log "Cannot copy the field run results."; return 1; }
	log "Field run done: $(cat "${results_dir}/${done_name}")"
	log "Field run summary: ✅ ${passed_results} pass, ❌ ${failed_results} fail, ${other_results} other."
	# A run a reload cut short is closed by the app with interrupted=true
	if [ "$(plutil -extract interrupted raw -o - "${results_dir}/${done_name}" 2>/dev/null)" = "true" ]; then
		return 2
	fi
	return 0
}

run_field_run 2>&1 | tee "${out}/field_run.txt"
field_run_status=${PIPESTATUS[0]}
# After the run, on the app it installed: the managed Ollama guardian refuses a
# launcher whose strict signature fails
# (OwnedSuspendedImageGuardian); a file written into the bundle breaks it.
step app_signature sh -c 'app="/Applications/$1"; verdict=$(codesign --verify --deep --strict "$app" 2>&1); status=$?; printf "%s\n" "$verdict" | sed "s#$HOME#~#g"; echo "codesign exit=$status"; n=$(find "$app/Contents" -name __pycache__ 2>/dev/null | wc -l | tr -d " "); echo "pycache_folders=$n"' sh "${ERGOPTI_APP_BUNDLE}"
# What no command can do on its own, said once instead of faked.
cat > "${out}/not_automated.txt" <<'NOTE'
typing through the owned runtime: refused. Karabiner captures the keyboards at the HID level, below the event system;
  synthetic key events (CGEvent) never reach it, and macOS offers no HID injection without a signed driver. The
  field run's tap-hold, chord and hotstring checks prove the rules and the Quartz path; typing on the internal keyboard
  stays a person's check.
sleep and wake: refused. Waking the Mac on its own needs a pmset power schedule, a system setting this collector never
  writes, and a sleeping Mac cannot run the collector.
driver approval and administrator password: a person's steps. macOS forbids clicking them for the user; the run waits.
reload: automated (the field run's owned_install_reload and driver_reload steps).
NOTE
printf '%-28s exit=%s\n' "field_run" "${field_run_status}" >> "${steps}"
[ "${field_run_status}" -eq 0 ] || log "step 'field_run' exited ${field_run_status} (kept in ${out}/field_run.txt)"

# The owned Ollama install of the 22:32 run of 2026-10-27 ended with exit 137
# (SIGKILL) and no output. These show which binaries it left, whether macOS
# accepts their signatures, and any kernel or code-signing kill around the run.
native_root="${HOME}/Library/Application Support/Ergopti"
step native_runtime sh -c '
	root="$1"
	for dir in "$root/native-bootstrap/bin" "$root/native-bootstrap/python-bin" "$root/ollama-native-http"; do
		printf "== %s\n" "$dir"; ls -la "$dir" 2>&1
	done
	for bin in "$root/native-bootstrap/bin/uv" "$root/ollama-native-http/ollama" "$root"/native-bootstrap/python-bin/python3*; do
		[ -e "$bin" ] || continue
		printf "== codesign %s\n" "$bin"; codesign --verify --strict --verbose=2 "$bin" 2>&1; codesign -dv "$bin" 2>&1 | head -8
	done
	printf "== diagnostic reports of the last hour\n"
	find "$HOME/Library/Logs/DiagnosticReports" -mmin -60 -type f 2>/dev/null | grep -iE "python|uv|ollama|bash|ErgoptiPlus" || true
	printf "== kernel and code-signing kills of the last 30 minutes\n"
	log show --last 30m --style compact --predicate "(process == \"kernel\" OR sender == \"AppleMobileFileIntegrity\") AND (eventMessage CONTAINS[c] \"code sign\" OR eventMessage CONTAINS[c] \"killed\" OR eventMessage CONTAINS[c] \"cs_invalid\" OR eventMessage CONTAINS[c] \"memorystatus\")" 2>&1 | tail -60
' native_runtime "${native_root}"

# The app's own crash reports of this run (the 2026-10-30 runs left
# ErgoptiPlus .ips files with no cause in the report): process, exception,
# signal, termination and the faulting thread's frames of the app's own
# images, scrubbed of paths and user data (tools/dev/field-ips-summary.py).
step crash_summaries python3 "${REPO_ROOT}/tools/dev/field-ips-summary.py" --since "${run_started_epoch}" \
	"${HOME}/Library/Logs/DiagnosticReports"

# The native PTY guardian runs its installer as /bin/bash /dev/fd/3 over an
# unlinked copy. On the 2026-10-27 runs that bash was killed by SIGKILL about
# 10 s after it started, before any output, and nothing in Ergopti sent it.
# The same shape from this shell, beside a plain script path, shows whether
# an endpoint-security agent kills fileless script execution on this Mac.
step security_agents sh -c '
	systemextensionsctl list 2>&1 | grep -v -i "com.apple" || true
	pgrep -lf -i "falcon|crowdstrike|sentinel|wdav|defender|jamf|cylance|carbonblack|cbagent|tanium|sophos|trend|zscaler|netskope|forcepoint|elastic|santa|kandji|mosyle|cortex|traps" || true
'
step fileless_bash_probe bash -c '
	[ "$(uname -s)" = Darwin ] || { printf "skipped: not a Mac\n"; exit 0; }
	dir="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-bash-probe.XXXXXX")" || exit 1
	# The test fixture shortens the run with FIELD_FILELESS_PROBE_SECONDS_OVERRIDE.
	printf "%s\n" "printf \"started\\n\"; sleep ${FIELD_FILELESS_PROBE_SECONDS_OVERRIDE:-12}; printf \"survived\\n\"" > "$dir/probe.sh"
	cp "$dir/probe.sh" "$dir/unlinked.sh"
	# Both shapes run at once: the kill came about 10 s in, so 12 s covers it.
	start=$(date +%s)
	( /bin/bash "$dir/probe.sh" > "$dir/path.out" 2>&1; printf "%s" "$?" > "$dir/path.status" ) &
	exec 3< "$dir/unlinked.sh"
	rm -f "$dir/unlinked.sh"
	( /bin/bash /dev/fd/3 > "$dir/fd.out" 2>&1; printf "%s" "$?" > "$dir/fd.status" ) &
	exec 3<&-
	wait
	elapsed=$(( $(date +%s) - start ))
	printf "path script: exit=%s output=%s\n" "$(cat "$dir/path.status")" "$(tr "\n" " " < "$dir/path.out")"
	printf "unlinked /dev/fd/3 script: exit=%s output=%s\n" "$(cat "$dir/fd.status")" "$(tr "\n" " " < "$dir/fd.out")"
	printf "both finished after %ss\n" "$elapsed"
	rm -rf "$dir"
'

# Checklist items that need no person: which privacy pane URL form this macOS
# opens (ledger L29) and the system bash 3.2 (tools/dev/macos-field-shell-checks.sh)
step privacy_pane_urls field_privacy_pane_urls "${REPO_ROOT}"
step system_bash field_system_bash

# ===========================================
# ======= 4/ Input-source probe =============
# ===========================================

probe_src="tools/diagnostics/macos_tis_register_probe.swift"
# A unique binary per run: a failed build must never leave an older probe to run.
probe_bin="/tmp/ep_tis_probe_${stamp}"
if [ -f "${probe_src}" ]; then
	log "Compiling and running the input-source probe (a few minutes, silent)..."
	step probe_compile swiftc -O -o "${probe_bin}" "${probe_src}"
	if [ -x "${probe_bin}" ]; then
		# A previous --write-prefs run kept one enabled layout and a marker for
		# the after-logout questions (P10, P8 a, P6). The probe names its own
		# marker; that run goes first, before a new run could keep another
		# layout, and it only says so when no logout happened since.
		probe_marker="$("${probe_bin}" marker-path)"
		if [ -n "${probe_marker}" ] && [ -f "${probe_marker}" ]; then
			step probe_after_logout "${probe_bin}" after-logout
		else
			printf '%-28s skipped (no marker from an earlier run)\n' "probe_after_logout" >> "${steps}"
		fi
		# Plain run, then the preferences route alone and with each re-read
		# mechanism (writes and restores com.apple.HIToolbox, keeps one layout
		# for the next run), then a layout added inside the enabled Ergopti
		# bundle and that bundle's content replaced in place (both backed up
		# and restored).
		step probe_run "${probe_bin}"
		step probe_write_prefs "${probe_bin}" --write-prefs
		step probe_replace_ergopti "${probe_bin}" --replace-ergopti --write-prefs
		rm -f "${probe_bin}"
	else
		printf '%-28s skipped (the probe did not compile)\n' "probe_runs" >> "$steps"
	fi
fi

# ===========================================
# ======= 5/ Logs, commit and push ==========
# ===========================================

finalize
