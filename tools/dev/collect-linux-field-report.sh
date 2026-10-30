#!/usr/bin/env bash
# tools/dev/collect-linux-field-report.sh

# ==============================================================================
# MODULE: Linux field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Linux desktop, the Linux
# counterpart of tools/dev/collect-macos-field-report.sh: it updates the field
# branch from its base (dev unless it was derived from another branch), gathers
# the evidence the coordinator reads (system, session, toolchain and input
# access facts, the driver's units and processes, today's ErgoptiPlus logs and
# their digest), stores it under docs/field-reports/, then commits and pushes
# the branch. The logs are gitignored, so they are added with `git add -f`; the
# logger already masks secrets, the home folder, e-mail addresses and personal
# names, and the branch is public, so only copies scrubbed of typed text by
# tools/dev/field-log-scrub.py leave the machine and the digests read those copies.
# The personal hotstrings file never travels: tools/dev/hotstring-collisions.py
# reports which of its triggers share a bundled one. The facts below have the home
# folder and the user name replaced.
#
# The logs folder is the one the driver itself resolves
# (infra/config_paths.lua get_logs_dir: the paths.logs_dir override, else
# ${XDG_STATE_HOME:-~/.local/state}/ergopti_plus/logs), asked through luajit.
#
# NOT COVERED, AND WHY:
# - No field run. The Linux daemon has no request protocol like the macOS
#   developer app's (infra/field_run.lua): its Debug field checks (composed
#   layout, network) run from the tray and show a zenity result a person
#   closes. Each check writes one "check=<id> verdict=<...>" line to the day
#   log, so the checks clicked today are in digest_field_checks; the collector
#   prints them with the macOS marks (✅ pass, ❌ fail, ⏭️ skip, ⌨️ needs_typing,
#   ⚠️ other) and a summary line, also kept in field_checks.txt.
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
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
# shellcheck source=field-report-git.sh
. "$REPO_ROOT/tools/dev/field-report-git.sh"
set +e
DRIVER_ROOT="$REPO_ROOT/static/ergopti_plus/linux"
SHARED_LUA="$REPO_ROOT/static/ergopti_plus/_shared/lua"
BUNDLED_HOTSTRINGS="$REPO_ROOT/static/ergopti_plus/_shared/modules/hotstrings"

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

# Runs one named step, captures its output into a file and records its status.
step() {
	local name="$1"; shift
	local file="${out}/${name}.txt"
	"$@" > "${file}" 2>&1
	local status=$?
	mask_file "${file}"
	printf '%-28s exit=%s\n' "${name}" "${status}" >> "${steps}"
	[ "${status}" -eq 0 ] || log "step '${name}' exited ${status} (kept in ${file})"
	return 0
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
# _shared/lua/app_dirs.lua, one per line: folder, unified prefix, errors prefix,
# extension, bootstrap log, crash reports folder, personal hotstrings file.
driver_log_layout() {
	LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;" \
		luajit -e '
			local dirs, files = require("app_dirs"), require("app_dirs").files
			print(require("infra.config_paths").get_logs_dir())
			print(files.unified_prefix); print(files.errors_prefix); print(files.extension)
			print(files.bootstrap_log); print(dirs.crash_reports_dir)
			print(require("infra.config_paths").config("personal_hotstrings.toml"))'
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
	local start_day today d f subject layout log_dir main errors ext bootstrap crashes personal
	local days=()
	# A run that crosses midnight spans two day logs: keep both, oldest first.
	start_day="${stamp%%_*}"
	today="$(date +%Y-%m-%d)"
	days=("${start_day}")
	[ "${today}" = "${start_day}" ] || days+=("${today}")
	if layout="$(driver_log_layout 2>"${out}/logs_dir.txt")"; then
		{ read -r log_dir; read -r main; read -r errors; read -r ext; read -r bootstrap; read -r crashes; read -r personal; } <<< "${layout}"
	fi
	if [ -z "${crashes:-}" ]; then
		printf '%-28s unresolved (luajit could not run infra/config_paths.lua, see logs_dir.txt)\n' "logs" >> "${steps}"
		mask_file "${out}/logs_dir.txt"
	elif [ -d "${log_dir}" ]; then
		: > "${out}/logs_dir.txt"
		for d in "${days[@]}"; do
			for f in "${log_dir}/${main}${d}${ext}" "${log_dir}/${errors}${d}${ext}"; do
				[ -f "${f}" ] && scrub_log "${f}"
			done
		done
		# The LLM sub-log keeps the download and server lines of earlier days.
		for f in "${log_dir}/${main}llm${ext}" "${log_dir}/${bootstrap}"; do
			[ -f "${f}" ] && scrub_log "${f}"
		done
		# Crash reports are named, not copied: a dump is read on request.
		step crash_reports sh -c 'ls -la "$1" 2>/dev/null || echo "no crash report"' sh "${log_dir}/${crashes}"
		local day_logs=()
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

	subject="docs(field): Linux field report ${stamp} on ${base}"
	"${interrupted}" && subject="${subject} (interrupted)"
	field_report_commit "${subject}"
}

# Ctrl-C or TERM: the logs are still copied, committed and pushed. A second
# signal during that work is ignored.
on_interrupt() {
	trap '' INT TERM HUP
	interrupted=true
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
step toolchain sh -c 'luajit -v; luajit -e "require(\"luv\"); print(\"luv ok\")"; for t in ydotool ydotoold zenity notify-send xdg-open cc; do printf "%s: %s\n" "$t" "$(command -v "$t" || echo missing)"; done; zenity --version'
step keyboard_layout sh -c 'localectl status; command -v setxkbmap >/dev/null && setxkbmap -query; command -v gsettings >/dev/null && gsettings get org.gnome.desktop.input-sources sources; true'
# Input access: the groups, uinput and the evdev nodes the daemon must open.
step input_access sh -c 'id -nG; ls -l /dev/uinput; n=0; r=0; for d in /dev/input/event*; do n=$((n + 1)); [ -r "$d" ] && r=$((r + 1)); done; echo "evdev nodes: $n, readable: $r"; ls /etc/udev/rules.d 2>/dev/null | grep -i ergopti || true'
step units sh -c 'systemctl --user list-units --all --no-pager "ergopti*"'
step processes sh -c 'pgrep -af "ergopti|ydotoold|ollama|llama-server|omlx|local-ai|lm-studio|jan" | grep -v pgrep || true'
# Loopback listeners show which local AI server runs (process names and ports).
step listeners sh -c 'ss -ltnpH 2>/dev/null || true'
step native_backend sh -c 'ls -l "$1"/bin/ 2>&1' sh "${DRIVER_ROOT}"

# ===========================================
# ======= 3/ Logs, commit and push ==========
# ===========================================

finalize
