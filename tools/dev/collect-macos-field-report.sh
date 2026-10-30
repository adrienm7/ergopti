#!/usr/bin/env bash
# tools/dev/collect-macos-field-report.sh

# ==============================================================================
# MODULE: macOS field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Mac: it updates the field
# branch from its base (dev unless it was derived from another branch), gathers the evidence the coordinator reads (system and
# toolchain facts, the field run of the developer app, the input-source probe,
# today's ErgoptiPlus logs and their digest), stores it under
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
# USAGE (from any branch: outside a field/ branch the collector switches to
# field/mac-<today>-<branch>, derived from that branch and created when
# missing; base.txt in the report names the base and the commit):
#   bash tools/dev/collect-macos-field-report.sh            update, collect, commit, push
#   bash tools/dev/collect-macos-field-report.sh --no-push  same, without the push
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
# How long the developer app may take to publish its readiness, and then to
# accept the request it was sent. Right after a reboot the 12:02 run of
# 2026-10-28 saw the ready app hold its main thread 138 s (keystats ledger
# replay) before it took the request, past the former 60 s. A field run test
# shortens the acceptance budget through FIELD_RUN_ACCEPT_SECONDS_OVERRIDE.
FIELD_RUN_READY_SECONDS=240
FIELD_RUN_ACCEPT_SECONDS="${FIELD_RUN_ACCEPT_SECONDS_OVERRIDE:-300}"
FIELD_RUN_POLL_SECONDS=5

fail() { printf '[field-report] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[field-report] %s\n' "$*"; }

push=true
case "$#:${1:-}" in
	0:) ;;
	1:--no-push) push=false ;;
	*) fail "Expected no argument or --no-push." ;;
esac

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
	local days=()
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
		for f in ${LOG_TOPICAL} "${LOG_LAUNCHER}"; do
			f="${LOG_DIR}/${f}"
			[ -f "${f}" ] && scrub_log "${f}"
		done
		local day_logs=()
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
	# Which personal triggers share a bundled one, with both sides' flags and no
	# replacement text: the personal file itself never travels.
	step hotstring_collisions python3 "${REPO_ROOT}/tools/dev/hotstring-collisions.py" \
		"${PERSONAL_HOTSTRINGS}" "${REPO_ROOT}/${BUNDLED_HOTSTRINGS}"

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
	if [ ! -x "${app_binary}" ]; then
		stale="no developer app is built"
	else
		stale="$(find "${REPO_ROOT}/static/ergopti_plus/macos/launcher" "${REPO_ROOT}/tools/build" \
			-type f -newer "${app_binary}" -print -quit 2>/dev/null)"
	fi
	# A readiness left by an app the runner is about to stop would send the
	# request to that app: only the readiness of the app opened here counts.
	if [ -n "${stale}" ] || ! ready_pid >/dev/null; then
		rm -f "${ready_file}" || { log "Cannot remove the previous readiness."; return 1; }
	fi
	if [ -n "${stale}" ]; then
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

	log "Waiting for the developer app to publish its readiness..."
	while ! pid="$(ready_pid)"; do
		now="$(date +%s)"
		if [ $((now - started_at)) -ge "${FIELD_RUN_READY_SECONDS}" ]; then
			log "No ready developer app after ${FIELD_RUN_READY_SECONDS} s. If an installed ${ERGOPTI_APP_NAME} is running, quit it and run this again."
			return 1
		fi
		sleep "${FIELD_RUN_POLL_SECONDS}"
	done
	log "Developer app ready (pid ${pid}); requesting every step within ${deadline_seconds} s."

	rm -f "${run_folder}/${refused_name}"
	printf '{"schema":1,"request_id":"%s","steps":["all"],"deadline_seconds":%s}\n' \
		"${request_id}" "${deadline_seconds}" > "${run_folder}/.${request_name}.tmp" \
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
		log "The field run was cut short in the app (see its log); the results so far are kept."
		return 1
	fi
	return 0
}

run_field_run 2>&1 | tee "${out}/field_run.txt"
field_run_status=${PIPESTATUS[0]}
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
	printf "%s\n" "printf \"started\\n\"; sleep 12; printf \"survived\\n\"" > "$dir/probe.sh"
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
