#!/usr/bin/env bash
# tools/build/write_build_stamp.sh
#
# Writes, or verifies, the build stamp of a macOS or Linux package.
#
# A packaged ErgoptiPlus.app or Linux package (.deb, .rpm, AppImage, Flatpak,
# tarball) ships no .git, so the drivers' diagnostics (healthcheck, boot
# snapshot, crash report) could not say which commit they were built from and
# printed "unknown". Every package build stamps the commit into the root of the
# shared tree it ships; both Lua drivers read it through
# _shared/lua/diagnostics/snapshot.lua (BUILD_STAMP_FILE, BUILD_STAMP_COMMIT_KEY),
# whose values tools/test/test-package-builds-stamp-commit.cjs pins to the two
# constants below. The Windows build stamps BUNDLE_COMMIT in infra/bundle.ahk.
#
# The commit is ERGOPTI_BUILD_COMMIT when set (CI passes github.sha), else the
# HEAD of this checkout. Anything that is not a full commit id is refused, so a
# package can never ship a stamp its readers would reject.
#
# Usage:
#   bash tools/build/write_build_stamp.sh write  <shared tree directory>
#   bash tools/build/write_build_stamp.sh verify <shared tree directory>

set -euo pipefail

BUILD_STAMP_FILE="build_stamp.txt"
BUILD_STAMP_COMMIT_KEY="commit"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"

fail() { printf '[build-stamp] ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || fail "usage: write_build_stamp.sh write|verify <shared tree directory>"
MODE="$1"
SHARED_DIR="$2"
[ -d "$SHARED_DIR" ] || fail "shared tree directory not found: $SHARED_DIR"
STAMP_PATH="${SHARED_DIR%/}/${BUILD_STAMP_FILE}"

# Fails unless the argument is a full, lowercase commit id.
require_full_commit() {
	[[ "$1" =~ ^[0-9a-f]{40}$ ]] || fail "$2 '$1' is not a full commit id"
}

case "$MODE" in
	write)
		if [ -n "${ERGOPTI_BUILD_COMMIT:-}" ]; then
			commit="$ERGOPTI_BUILD_COMMIT"
			origin="ERGOPTI_BUILD_COMMIT"
		else
			commit="$(git -C "$REPO_ROOT" rev-parse HEAD)" \
				|| fail "ERGOPTI_BUILD_COMMIT is unset and $REPO_ROOT is not a git checkout"
			origin="git HEAD of $REPO_ROOT"
		fi
		require_full_commit "$commit" "$origin"
		printf '%s=%s\n' "$BUILD_STAMP_COMMIT_KEY" "$commit" > "$STAMP_PATH"
		echo "[build-stamp] ${BUILD_STAMP_COMMIT_KEY}=${commit} (${origin}) -> ${STAMP_PATH}"
		;;
	verify)
		[ -f "$STAMP_PATH" ] || fail "no build stamp at $STAMP_PATH — the package would report an unknown commit"
		line="$(grep -E "^${BUILD_STAMP_COMMIT_KEY}=" "$STAMP_PATH" || true)"
		[ -n "$line" ] || fail "$STAMP_PATH has no ${BUILD_STAMP_COMMIT_KEY}= entry"
		require_full_commit "${line#*=}" "$STAMP_PATH"
		echo "[build-stamp] verified ${line} in ${STAMP_PATH}"
		;;
	*)
		fail "unknown mode '$MODE' (expected write or verify)"
		;;
esac
