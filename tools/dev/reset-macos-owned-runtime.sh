#!/usr/bin/env bash
# tools/dev/reset-macos-owned-runtime.sh

# ==============================================================================
# MODULE: macOS unfinished owned runtime install reset (field reports)
# DESCRIPTION:
# Removes what a first install of Ergopti's own Karabiner runtime left behind
# when it stopped before its services: the published Runtime folder, the
# install journal and the stage folders of earlier attempts, all under
# /Library/Application Support/ErgoptiPlus. The installer helper never rolls
# back a transaction that crossed publication, and refuses to install over an
# existing Runtime (field report 2026-11-09: refused-destination after the
# 2026-11-08 attempt), so a field Mac stayed blocked until a person removed
# them by hand.
#
# USAGE:
#   bash tools/dev/reset-macos-owned-runtime.sh
#
# It changes nothing unless the leftovers are those of an unfinished first
# install: no owned LaunchDaemon file and no loaded owned job. A finished
# install is never touched (exit 0, said so). It names each path, then
# removes exactly those with one administrator password (sudo). The lifecycle
# lock and the parent folder stay. Exit 1 only when a removal fails.
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "$PWD")"
REPO_ROOT="${REPO_ROOT%.}"
# shellcheck source=../../static/ergopti_plus/_shared/core/text/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/core/text/data/identifiers.sh"

fail() { printf '[owned-runtime-reset] REFUSED: %s\n' "$*" >&2; exit 1; }
log() { printf '[owned-runtime-reset] %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || fail "a Mac is required."
[ "$#" -eq 0 ] || fail "Expected no argument."

PARENT="/Library/Application Support/ErgoptiPlus"
[ -d "$PARENT" ] || { log "No $PARENT: nothing to remove."; exit 0; }

# A finished install has its daemon files and jobs: never touch it.
for label in "$ERGOPTI_SERVICE_LABEL_MACOS_CORE" "$ERGOPTI_SERVICE_LABEL_MACOS_VIRTUAL_HID"; do
	if [ -e "/Library/LaunchDaemons/$label.plist" ]; then
		log "/Library/LaunchDaemons/$label.plist exists: the install went past its files; nothing is removed."
		exit 0
	fi
	status=0
	launchctl print "system/$label" >/dev/null 2>&1 || status=$?
	# launchctl print exits 113 for a service it does not know.
	if [ "$status" -ne 113 ]; then
		log "system/$label answers launchctl print (exit $status): a runtime job is loaded; nothing is removed."
		exit 0
	fi
done

# The parent folder lists without a password; its stage folders and Runtime do not.
leftovers=()
for name in "Runtime" ".runtime-install-journal"; do
	if [ -e "$PARENT/$name" ] || [ -L "$PARENT/$name" ]; then leftovers+=("$PARENT/$name"); fi
done
while IFS= read -r entry; do
	[[ "$entry" =~ ^\.runtime-(installer|install)-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] \
		&& leftovers+=("$PARENT/$entry")
done < <(ls -A "$PARENT")
if [ "${#leftovers[@]}" -eq 0 ]; then
	log "No leftover of an unfinished install in $PARENT."
	exit 0
fi

log "An earlier owned runtime install stopped before its services and left:"
for path in "${leftovers[@]}"; do log "  $path"; done
log "Removing them (macOS asks for your administrator password)..."
sudo /bin/rm -rf -- "${leftovers[@]}" || fail "the leftovers could not be removed."
for path in "${leftovers[@]}"; do
	[ ! -e "$path" ] || fail "$path is still there."
done
log "Removed. The next install starts from a clean folder."
