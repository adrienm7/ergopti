#!/usr/bin/env bash
# tools/dev/collect-macos-field-report.sh

# ==============================================================================
# MODULE: macOS field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Mac: it updates the field
# branch from dev, gathers the evidence the coordinator reads (system and
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
# within a global deadline and copies its results.
#
# USAGE:
#   bash tools/dev/collect-macos-field-report.sh            update, collect, commit, push
#   bash tools/dev/collect-macos-field-report.sh --no-push  same, without the push
#
# Each step records its exit status in steps.txt; a failed step never hides
# the others, and the summary names it.
# ==============================================================================

set -uo pipefail

# Command substitution removes trailing LF bytes, even when they belong to a
# directory name. Capture a sentinel and remove only that final byte afterward.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "${PWD}")"
REPO_ROOT="${REPO_ROOT%.}"
LOG_DIR="${HOME}/Library/Logs/ergopti_plus"
FIELD_BRANCH_PREFIX="field/"
FIELD_RUN_SPEC="static/ergopti_plus/macos/data/field_run.json"
# The whole field run, from the app start to its done marker. The request's own
# deadline is the declared default, below this one, so done arrives first.
FIELD_RUN_DEADLINE_SECONDS=900
# How long the developer app may take to publish its readiness, and to accept.
FIELD_RUN_READY_SECONDS=240
FIELD_RUN_ACCEPT_SECONDS=60
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

branch="$(git branch --show-current)"
case "${branch}" in
	"${FIELD_BRANCH_PREFIX}"*) ;;
	*) fail "Switch to your field branch first (git switch -c ${FIELD_BRANCH_PREFIX}mac-$(date +%Y-%m-%d)); current: '${branch:-detached}'." ;;
esac
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Commit or discard the tracked changes first: the collector commits only its own folder."

# ===========================================
# ======= 1/ Update from dev ================
# ===========================================

# A shallow clone (--depth 1) holds no common ancestor of dev and the field
# branch, so a plain merge refuses "unrelated histories". Deepen both until the
# merge base is known; full history is never downloaded.
log "Fetching dev and bringing it into ${branch}..."
depth=50
while :; do
	git fetch -q --depth "${depth}" origin dev || fail "git fetch of dev failed."
	dev_head="$(git rev-parse FETCH_HEAD)" || fail "Cannot read the fetched dev head."
	git merge-base HEAD "${dev_head}" >/dev/null 2>&1 && break
	[ "${depth}" -lt 3200 ] || fail "No common history with dev within ${depth} commits; re-clone with --depth 1."
	depth=$((depth * 4))
done
git merge --ff-only "${dev_head}" >/dev/null 2>&1 \
	|| git merge --no-edit "${dev_head}" \
	|| fail "Could not bring dev into ${branch}; resolve the merge and run again."

stamp="$(date +%Y-%m-%d_%H%M%S)"
out="docs/field-reports/mac-${stamp}"
mkdir -p "${out}" || fail "Cannot create ${out}."
steps="${out}/steps.txt"
: > "${steps}"

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

# ===========================================
# ======= 2/ System and toolchain ===========
# ===========================================

step versions sh -c 'git rev-parse --short HEAD; sw_vers; uname -m; sysctl -n hw.ncpu hw.memsize'
step toolchain sh -c 'xcode-select -p; swift --version; swift build --version; which -a swift'
step karabiner sh -c '"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli" --version'
step memory sh -c 'memory_pressure | tail -1; vm_stat | head -5'
step processes sh -c 'pgrep -lf "ErgoptiPlus|Hammerspoon|karabiner|ollama|omlx" || true'
step launchd sh -c 'launchctl list | grep -iE "ergopti|pqrs" || true'
step listeners sh -c 'lsof -nP -iTCP -sTCP:LISTEN | grep -iE "ollama|omlx|hammerspoon" || true'
step input_sources sh -c 'defaults read com.apple.HIToolbox AppleEnabledInputSources; defaults read com.apple.HIToolbox AppleSelectedInputSources'
step user_layouts sh -c 'ls -la "${HOME}/Library/Keyboard Layouts" 2>&1'

# ===========================================
# ======= 3/ Field run in the app ===========
# ===========================================

# Reads one value of the field run declaration.
spec_value() {
	plutil -extract "$1" raw -o - "${REPO_ROOT}/${FIELD_RUN_SPEC}"
}

# Prints the pid a readiness file names when that process is alive.
ready_pid() {
	local pid
	[ -f "${ready_file}" ] || return 1
	pid="$(plutil -extract pid raw -o - "${ready_file}" 2>/dev/null)" || return 1
	case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "${pid}" 2>/dev/null || return 1
	printf '%s\n' "${pid}"
}

# Prints each step result once, as it appears.
report_new_results() {
	local file name verdict
	for file in "${results_dir}"/[0-9][0-9]_*.json; do
		[ -f "${file}" ] || continue
		name="$(basename "${file}" .json)"
		case " ${seen_results} " in *" ${name} "*) continue ;; esac
		seen_results="${seen_results} ${name}"
		verdict="$(plutil -extract verdict raw -o - "${file}" 2>/dev/null || printf 'unreadable')"
		log "  field run ${name}: ${verdict}"
	done
}

# Opens the developer app, sends the request, waits for done and copies it.
run_field_run() {
	. "${REPO_ROOT}/static/ergopti_plus/_shared/data/identifiers.sh"
	local folder request_name accepted_name done_name refused_name request_id deadline_seconds
	folder="$(spec_value folder)" || { log "Cannot read ${FIELD_RUN_SPEC}."; return 1; }
	run_folder="${REPO_ROOT}/${folder}"
	ready_file="${run_folder}/$(spec_value files.ready)"
	request_name="$(spec_value files.request)"
	refused_name="$(spec_value files.refused)"
	accepted_name="$(spec_value files.accepted)"
	done_name="$(spec_value files.done)"
	deadline_seconds="$(spec_value deadline_seconds.default)"
	request_id="mac-${stamp}"
	results_dir="${run_folder}/$(spec_value files.results)/${request_id}"
	seen_results=""
	local started_at now pid
	started_at="$(date +%s)"

	if ! pgrep -x "${ERGOPTI_APP_NAME}" >/dev/null 2>&1; then
		if [ -d "${REPO_ROOT}/build/macos/${ERGOPTI_APP_BUNDLE}" ]; then
			log "Opening the developer app..."
			bash "${REPO_ROOT}/tools/dev/run-macos-dev-app.sh" --open-only \
				|| bash "${REPO_ROOT}/tools/dev/run-macos-dev-app.sh" \
				|| { log "The developer app could not be opened."; return 1; }
		else
			log "Building and opening the developer app (first run, a few minutes)..."
			bash "${REPO_ROOT}/tools/dev/run-macos-dev-app.sh" || { log "The developer app could not be built."; return 1; }
		fi
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
	local sent_at last_note
	sent_at="$(date +%s)"
	last_note="${sent_at}"

	while [ ! -f "${results_dir}/${done_name}" ]; do
		if [ -f "${run_folder}/${refused_name}" ]; then
			log "The app refused the request: $(cat "${run_folder}/${refused_name}")"
			cp "${run_folder}/${refused_name}" "${out}/field_run_refused.json"
			return 1
		fi
		now="$(date +%s)"
		if [ ! -f "${results_dir}/${accepted_name}" ] && [ $((now - sent_at)) -ge "${FIELD_RUN_ACCEPT_SECONDS}" ]; then
			log "The app did not accept the request within ${FIELD_RUN_ACCEPT_SECONDS} s."
			return 1
		fi
		if [ $((now - started_at)) -ge "${FIELD_RUN_DEADLINE_SECONDS}" ]; then
			log "No done marker after ${FIELD_RUN_DEADLINE_SECONDS} s; keeping the partial results."
			report_new_results
			[ -d "${results_dir}" ] && cp -R "${results_dir}" "${out}/field_run"
			return 1
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
	cp -R "${results_dir}" "${out}/field_run" || { log "Cannot copy the field run results."; return 1; }
	log "Field run done: $(cat "${results_dir}/${done_name}")"
	return 0
}

run_field_run 2>&1 | tee "${out}/field_run.txt"
field_run_status=${PIPESTATUS[0]}
printf '%-28s exit=%s\n' "field_run" "${field_run_status}" >> "${steps}"
[ "${field_run_status}" -eq 0 ] || log "step 'field_run' exited ${field_run_status} (kept in ${out}/field_run.txt)"

# ===========================================
# ======= 4/ Input-source probe =============
# ===========================================

probe_src="tools/diagnostics/macos_tis_register_probe.swift"
# A unique binary per run: a failed build must never leave an older probe to run.
probe_bin="/tmp/ep_tis_probe_${stamp}"
if [ -f "${probe_src}" ]; then
	step probe_compile swiftc -O -o "${probe_bin}" "${probe_src}"
	if [ -x "${probe_bin}" ]; then
		# Plain run, then the driver's own enabling route (writes and restores
		# com.apple.HIToolbox, restarts SystemUIServer), then a layout added
		# inside the enabled Ergopti bundle (backed up and restored).
		step probe_run "${probe_bin}"
		step probe_write_prefs "${probe_bin}" --write-prefs
		step probe_replace_ergopti "${probe_bin}" --replace-ergopti --write-prefs
		rm -f "${probe_bin}"
	else
		printf '%-28s skipped (the probe did not compile)\n' "probe_runs" >> "$steps"
	fi
fi

# ===========================================
# ======= 5/ Logs and their digest ==========
# ===========================================

today="$(date +%Y-%m-%d)"
if [ -d "${LOG_DIR}" ]; then
	for f in "${LOG_DIR}"/ErgoptiPlus_"${today}".log "${LOG_DIR}"/ErgoptiPlus_errors_"${today}".log \
		"${LOG_DIR}"/ErgoptiPlus_llm.log "${LOG_DIR}"/launcher.log; do
		[ -f "${f}" ] && cp "${f}" "${out}/" && printf '%-28s copied\n' "$(basename "${f}")" >> "${steps}"
	done
	day="${LOG_DIR}/ErgoptiPlus_${today}.log"
	if [ -f "${day}" ]; then
		step digest_boot grep -E "Boot complete|Boot CPU|Boot stage completed|held the main thread" "${day}"
		step digest_slow grep -E "\[HotPath\]|Slow " "${day}"
		step digest_errors grep -E "\[(ERROR|WARNING)\]" "${day}"
		step digest_input grep -E "key_event_health|karabiner.lease|guardian" "${day}"
	fi
else
	printf '%-28s missing\n' "logs" >> "${steps}"
fi

# ===========================================
# ======= 6/ Commit and push ================
# ===========================================

log "Collected into ${out}:"
ls -1 "${out}" | sed 's/^/  /'
git add -f -- "${out}" || fail "git add of ${out} failed."
git commit -q -m "docs(field): macOS field report ${stamp}" -- "${out}" || fail "git commit failed."
if [ "${push}" = true ]; then
	git push -u origin HEAD || fail "git push failed; run 'git push -u origin HEAD' by hand."
	log "Pushed ${branch}. Tell the coordinator: report ${out}."
else
	log "Committed on ${branch} without pushing."
fi
