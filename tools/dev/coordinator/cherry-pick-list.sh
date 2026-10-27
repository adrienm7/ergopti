#!/usr/bin/env bash
# tools/dev/coordinator/cherry-pick-list.sh

# ==============================================================================
# MODULE: Cherry-pick a commit list
# DESCRIPTION:
# Cherry-picks the commits of a list file ("<sha> <subject>" per line) onto the
# current branch, in order, and stops at the first conflict so it is resolved
# by hand (then `git cherry-pick --continue` and run again with that sha as the
# resume point). A pick that is already on the branch (empty) is skipped.
#
# USAGE:
#   bash tools/dev/coordinator/cherry-pick-list.sh <list-file> [resume-after-sha]
# ==============================================================================

set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <list-file> [resume-after-sha]" >&2; exit 64; }
LIST="$1"
AFTER="${2:-}"
started=true
[ -n "$AFTER" ] && started=false

while read -r sha subject; do
	[ -n "$sha" ] || continue
	if [ "$started" = false ]; then
		case "$sha" in "$AFTER"*) started=true ;; esac
		continue
	fi
	if ! git cherry-pick "$sha" >/dev/null 2>&1; then
		if [ -z "$(git diff --name-only --diff-filter=U)" ] && git diff --quiet HEAD; then
			git cherry-pick --skip >/dev/null 2>&1
			echo "EMPTY $sha $subject"
		else
			echo "CONFLICT $sha $subject"
			git diff --name-only --diff-filter=U
			exit 1
		fi
	fi
done < "$LIST"
echo "DONE"
