#!/usr/bin/env bash
# tools/dev/macos-field-shell-checks.sh

# ==============================================================================
# MODULE: macOS field shell checks
# DESCRIPTION:
# Maintainer checklist items that need no person and no driver, run by
# tools/dev/collect-macos-field-report.sh on the real Mac. Each check prints
# one "check=<id> verdict=<pass|fail|info> codes=<closed codes>" line, then its
# raw evidence; the collector keeps the output as one step file.
#
# FEATURES & RATIONALE:
# 1. Privacy pane URL forms (ledger L29): every pane of
#    static/ergopti_plus/macos/data/privacy_panes.json is opened in every form
#    with /usr/bin/open, whose exit code proves which form this macOS accepts.
#    System Settings is quit afterwards only when it was not running before,
#    so the session is left as found.
# 2. System bash 3.2 (checklist section 7): `pipefail` must make a pipeline
#    fail when its first command fails, and `printf %b` must expand escapes,
#    under /bin/bash itself, which the collector does not run under.
#
# Sourced only; defines functions and runs nothing.
# ==============================================================================

PRIVACY_PANES_SPEC="static/ergopti_plus/macos/data/privacy_panes.json"
# How long System Settings may take to take a URL before the next one.
PRIVACY_PANE_SETTLE_SECONDS=2

# Opens every privacy pane in every form and records each exit code.
# $1: clone root.
field_privacy_pane_urls() {
	local root="$1" spec forms panes form pane prefix anchor status codes="" accepted=0 refused=0
	local was_running=false
	spec="${root}/${PRIVACY_PANES_SPEC}"
	[ -f "${spec}" ] || { printf 'check=privacy_pane_urls verdict=fail codes=spec_missing\n'; return 1; }
	pgrep -xq "System Settings" && was_running=true
	# The forms are the table's two keys; the panes are read from the table
	forms="legacy extension"
	panes="$(plutil -extract panes json -o - "${spec}" | grep -oE '"[a-z_]+":' | tr -d '":' | tr '\n' ' ')"
	[ -n "${panes}" ] || { printf 'check=privacy_pane_urls verdict=fail codes=panes_unreadable\n'; return 1; }
	for pane in ${panes}; do
		anchor="$(plutil -extract "panes.${pane}" raw -o - "${spec}")"
		for form in ${forms}; do
			prefix="$(plutil -extract "forms.${form}" raw -o - "${spec}")"
			/usr/bin/open "${prefix}${anchor}" >/dev/null 2>&1
			status=$?
			printf '  %-18s %-10s exit=%s %s\n' "${pane}" "${form}" "${status}" "${prefix}${anchor}"
			codes="${codes}${codes:+,}${pane}_${form}_exit_${status}"
			if [ "${status}" -eq 0 ]; then accepted=$((accepted + 1)); else refused=$((refused + 1)); fi
			sleep "${PRIVACY_PANE_SETTLE_SECONDS}"
		done
	done
	if [ "${was_running}" = false ]; then
		/usr/bin/osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1
		printf '  System Settings quit (it was not running before)\n'
	else
		printf '  System Settings left open (it was running before)\n'
	fi
	# Info: the codes are the evidence; the adapter's choice is read against them
	printf 'check=privacy_pane_urls verdict=info codes=%s accepted=%s refused=%s\n' "${codes}" "${accepted}" "${refused}"
	return 0
}

# Checks pipefail and printf %b under the system /bin/bash.
field_system_bash() {
	local version pipe_status printf_bytes verdict=pass codes=""
	version="$(/bin/bash -c 'printf "%s" "${BASH_VERSION}"')"
	pipe_status="$(/bin/bash -c 'set -o pipefail; false | true; printf "%s" "$?"')"
	printf_bytes="$(/bin/bash -c 'printf "%b" "a\\tb"' | od -An -c | tr -s ' ')"
	printf '  bash=%s pipefail_status=%s printf_b=%s\n' "${version}" "${pipe_status}" "${printf_bytes}"
	case "${version}" in 3.2*) codes="bash_3_2" ;; *) codes="bash_${version%%.*}" ;; esac
	if [ "${pipe_status}" = "1" ]; then codes="${codes},pipefail_ok"; else verdict=fail; codes="${codes},pipefail_${pipe_status:-none}"; fi
	case "${printf_bytes}" in
		*'a \t b'*) codes="${codes},printf_b_ok" ;;
		*) verdict=fail; codes="${codes},printf_b_wrong" ;;
	esac
	printf 'check=system_bash verdict=%s codes=%s\n' "${verdict}" "${codes}"
	[ "${verdict}" = pass ]
}
