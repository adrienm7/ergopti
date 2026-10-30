#!/usr/bin/env bash
# tools/dev/field-report-git.sh

# ==============================================================================
# MODULE: Field report branch and commit
# DESCRIPTION:
# The git half that the macOS and Linux field report collectors share
# (tools/dev/collect-macos-field-report.sh, collect-linux-field-report.sh); the
# Windows collector (collect-windows-field-report.ps1) follows the same steps in
# PowerShell. The names come from the field_report group of
# static/ergopti_plus/_shared/data/identifiers.sh, which the caller sources
# first, with its own fail() and log().
#
# FEATURES & RATIONALE:
# 1. From any branch or a detached commit, the report goes to
#    field/<os>-<today>-<branch>, derived from it and reused when it exists;
#    git config remembers the base, so a later run on that field branch keeps
#    it (dev when nothing was recorded).
# 2. A shallow clone (--depth 1) holds no common ancestor of the base and the
#    field branch, so the update deepens both until the merge base is known;
#    full history is never downloaded. A base that is not a branch on origin
#    (a local branch or a commit) is not updated.
# 3. When the update moves the branch, the collector runs again from the
#    updated files: bash keeps executing the version it started with, so
#    without the rerun a fix pushed to the base would only apply next time.
# 4. base.txt is written first: the coordinator reads which code the report
#    ran on before anything else.
# 5. Only the report folder is committed, with `git add -f` because the logs
#    it holds are gitignored.
#
# Sourced only; defines functions and runs nothing. Bash 3.2 compatible: the
# macOS collector runs under the system bash.
# ==============================================================================

# Switches to the field branch of this run.
# $1: OS tag of the branch and report folder (mac, linux).
# Sets: branch (the field branch), base (the branch it is updated from).
field_report_enter_branch() {
	local tag="$1"
	[ -z "$(git status --porcelain --untracked-files=no)" ] \
		|| fail "Commit or discard the tracked changes first: the collector commits only its own folder."
	branch="$(git branch --show-current)"
	case "${branch}" in
		"${ERGOPTI_FIELD_REPORT_BRANCH_PREFIX}"*)
			base="$(git config --get "branch.${branch}.${ERGOPTI_FIELD_REPORT_BASE_CONFIG_KEY}" || printf 'dev')"
			;;
		*)
			base="${branch:-$(git rev-parse --short HEAD)}"
			branch="${ERGOPTI_FIELD_REPORT_BRANCH_PREFIX}${tag}-$(date +%Y-%m-%d)-${base//\//-}"
			if git rev-parse -q --verify "refs/heads/${branch}" >/dev/null; then
				git switch -q "${branch}" || fail "Cannot switch to ${branch}."
			else
				git switch -q -c "${branch}" || fail "Cannot create ${branch}."
			fi
			git config "branch.${branch}.${ERGOPTI_FIELD_REPORT_BASE_CONFIG_KEY}" "${base}" \
				|| fail "Cannot record the base of ${branch}."
			log "Collecting on ${branch}, derived from ${base}."
			;;
	esac
}

# Brings the base from origin into the field branch (uses branch and base),
# then runs the collector again when that moved the branch.
# $1: the collector script; the remaining arguments are its own.
field_report_update_from_base() {
	local script="$1" depth base_head before
	shift
	before="$(git rev-parse HEAD)" || fail "Cannot read HEAD."
	if ! git ls-remote --exit-code --heads origin "${base}" >/dev/null 2>&1; then
		log "${base} is not a branch on origin: ${branch} is not updated."
		return 0
	fi
	log "Fetching ${base} and bringing it into ${branch}..."
	depth=50
	while :; do
		git fetch -q --depth "${depth}" origin "${base}" || fail "git fetch of ${base} failed."
		base_head="$(git rev-parse FETCH_HEAD)" || fail "Cannot read the fetched ${base} head."
		git merge-base HEAD "${base_head}" >/dev/null 2>&1 && break
		[ "${depth}" -lt 3200 ] || fail "No common history with ${base} within ${depth} commits; re-clone with --depth 1."
		depth=$((depth * 4))
	done
	git merge --ff-only "${base_head}" >/dev/null 2>&1 \
		|| git merge --no-edit "${base_head}" \
		|| fail "Could not bring ${base} into ${branch}; resolve the merge and run again."
	[ "$(git rev-parse HEAD)" != "${before}" ] || return 0
	# The rerun finds HEAD current, so it never loops; the marker is a guard.
	[ -z "${ERGOPTI_FIELD_REPORT_RERUN:-}" ] || fail "The rerun moved ${branch} again; run the collector again."
	log "${branch} updated: running the updated collector."
	ERGOPTI_FIELD_REPORT_RERUN=1 exec bash "${script}" "$@"
}

# Creates this run's report folder with an empty steps.txt and its base.txt.
# $1: OS tag of the report folder (mac, linux).
# Sets: stamp, out (the folder, relative to the clone root), steps.
field_report_open_folder() {
	local tag="$1"
	stamp="$(date +%Y-%m-%d_%H%M%S)"
	out="${ERGOPTI_FIELD_REPORT_FOLDER}/${tag}-${stamp}"
	# Two runs within one second would share a folder and one base.txt.
	[ ! -e "${out}" ] || fail "${out} already exists; run the collector again."
	mkdir -p "${out}" || fail "Cannot create ${out}."
	steps="${out}/steps.txt"
	: > "${steps}"
	printf 'field_branch: %s\nbase: %s\ncommit: %s\n' "${branch}" "${base}" "$(git rev-parse --short HEAD)" > "${out}/base.txt" \
		|| fail "Cannot write ${out}/base.txt."
}

# Commits the report folder alone, then pushes unless push=false.
# $1: commit subject.
field_report_commit() {
	local subject="$1"
	log "Collected into ${out}:"
	ls -1 "${out}" | sed 's/^/  /'
	git add -f -- "${out}" || fail "git add of ${out} failed."
	git commit -q -m "${subject}" -- "${out}" || fail "git commit failed."
	if [ "${push}" = true ]; then
		git push -u origin HEAD || fail "git push failed; run 'git push -u origin HEAD' by hand."
		log "Pushed ${branch}. Tell the coordinator: report ${out}."
	else
		log "Committed on ${branch} without pushing."
	fi
}
