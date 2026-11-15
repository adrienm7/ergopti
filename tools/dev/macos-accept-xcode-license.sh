#!/usr/bin/env bash
# tools/dev/macos-accept-xcode-license.sh

# ==============================================================================
# MODULE: Xcode license acceptance (field reports)
# DESCRIPTION:
# A full Xcode whose license was never accepted makes every /usr/bin shim
# (python3, clang, swift, xcrun) exit 69 with "You have not agreed to the Xcode
# license agreements": the 2026-11-15 field report stopped there (the dev
# prerelease installer read its defaults with /usr/bin/python3, and the probe
# did not compile). This accepts it once, with the administrator password,
# so a tester never has to run sudo xcodebuild -license by hand.
#
# USAGE:
#   bash tools/dev/macos-accept-xcode-license.sh
#
# A Mac with only the Command Line Tools (no Xcode.app selected) has no license
# to accept and is left alone. Exits 0 when nothing blocks the shims, 1 when the
# license is still not accepted.
# ==============================================================================

set -uo pipefail

log() { printf '[xcode-license] %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || exit 0
developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
case "${developer_dir}" in
	*.app/Contents/Developer) ;;
	*) exit 0 ;;
esac
# xcodebuild -license check exits nonzero only while the license is pending.
/usr/bin/xcodebuild -license check >/dev/null 2>&1 && exit 0

log "Xcode's license is not accepted yet: python3, swift and clang refuse to run until it is."
log "Accepting it now (macOS asks for your administrator password)..."
if sudo /usr/bin/xcodebuild -license accept; then
	log "Xcode's license is accepted."
	exit 0
fi
log "Xcode's license could not be accepted: run 'sudo xcodebuild -license accept', then run this again."
exit 1
