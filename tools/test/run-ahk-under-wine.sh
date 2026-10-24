#!/usr/bin/env bash
# tools/test/run-ahk-under-wine.sh
#
# Runs one Windows driver test runner (run_all.ahk by default) under Wine on
# Linux and returns AutoHotkey's own exit code, so Windows code can be checked
# from a Linux machine before the Windows CI sees it.
#
# Wine is not Windows: the families it runs reliably and the ones it does not
# (low-level hooks, SendInput, WebView2, some native file semantics) are listed
# in docs/memory/windows-ahk.md (project-ahk-suite-under-wine). A red under Wine
# is a lead to confirm, never a verdict; a green does not replace the Windows CI.
#
# The script installs nothing. It needs, already present:
#   - wine (9.0 or later) on PATH, with an initialised WINEPREFIX;
#   - an X display in DISPLAY (Xvfb is enough: AHK creates hidden windows);
#   - the AutoHotkey v2 interpreter pinned in
#     static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json,
#     extracted from its release zip after checking that file's sha256.
#
# Usage:
#   bash tools/test/run-ahk-under-wine.sh --ahk <AutoHotkey64.exe> [options] [-- runner-args...]
#
# Options:
#   --ahk <path>      AutoHotkey64.exe to run (required).
#   --runner <file>   Runner relative to static/ergopti_plus/windows/tests,
#                     default run_all.ahk (e.g. e2e/run_e2e.ahk).
#   --results <file>  TAP receipt the runner writes (ERGOPTI_AHK_RESULTS_FILE),
#                     default a new temporary file whose path is printed.
#   Everything after -- goes to the runner unchanged: --module=<group>,
#   --only <substr>, --dry-run, --list=<file>, as in run_all.ahk's header.
#
# Example:
#   Xvfb :99 & export DISPLAY=:99 WINEPREFIX=$HOME/.wine-ergopti
#   bash tools/test/run-ahk-under-wine.sh --ahk ~/ahk/AutoHotkey64.exe -- --module=config-transition
#
# run_all.ahk is #SingleInstance Force: a second runner in the same WINEPREFIX
# silently kills the first, so the script refuses to start next to one. Use one
# WINEPREFIX (and one display) per concurrent run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TESTS_DIR="$PROJECT_ROOT/static/ergopti_plus/windows/tests"
SELF="tools/test/run-ahk-under-wine.sh"

die() {
	echo "$SELF: $*" >&2
	exit 2
}

ahk=""
runner="run_all.ahk"
results=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--ahk)
			[ "$#" -ge 2 ] || die "--ahk requires a path"
			ahk="$2"
			shift 2
			;;
		--runner)
			[ "$#" -ge 2 ] || die "--runner requires a file"
			runner="$2"
			shift 2
			;;
		--results)
			[ "$#" -ge 2 ] || die "--results requires a file"
			results="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		*)
			die "unknown option '$1' (runner arguments go after --)"
			;;
	esac
done

[ -n "$ahk" ] || die "--ahk <AutoHotkey64.exe> is required"
[ -f "$ahk" ] || die "AutoHotkey interpreter not found: $ahk"
[ -f "$TESTS_DIR/$runner" ] || die "runner not found: $TESTS_DIR/$runner"
command -v wine >/dev/null || die "wine is not on PATH; install it first (this script installs nothing)"
command -v winepath >/dev/null || die "winepath is not on PATH; it ships with wine"
[ -n "${DISPLAY:-}" ] || die "DISPLAY is not set; start an X server such as Xvfb and export DISPLAY"

prefix="${WINEPREFIX:-$HOME/.wine}"
[ -d "$prefix/drive_c" ] || die "WINEPREFIX $prefix is not initialised; run wineboot -i first"

# Another AutoHotkey in this prefix would be killed by #SingleInstance Force,
# or would kill this run: both leave a truncated receipt that looks like a red.
# Only argv[0] names the Windows image Wine runs; a launcher (this script, wine,
# timeout) merely carries the interpreter path as an argument.
for proc in /proc/[0-9]*; do
	image="$(tr '\0' '\n' <"$proc/cmdline" 2>/dev/null | head -n 1 || true)"
	image="${image##*[/\\]}"
	case "${image,,}" in
		autohotkey*.exe) ;;
		*) continue ;;
	esac
	other="$(tr '\0' '\n' <"$proc/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p')"
	if [ "${other:-$HOME/.wine}" = "$prefix" ]; then
		die "AutoHotkey already runs in $prefix (pid ${proc#/proc/}); use another WINEPREFIX"
	fi
done

if [ -z "$results" ]; then
	results="$(mktemp --suffix=.tap)"
fi
# As in CI: the runner creates its receipt, so a stale one cannot pass for it.
rm -f "$results"
ERGOPTI_AHK_RESULTS_FILE="$(winepath -w "$results" 2>/dev/null)"
[ -n "$ERGOPTI_AHK_RESULTS_FILE" ] || die "winepath could not map $results"
export ERGOPTI_AHK_RESULTS_FILE
# Wine's own debug channels would interleave with the runner's TAP on stderr.
export WINEDEBUG="${WINEDEBUG:--all}"

echo "AHK runtime : $ahk"
echo "Test runner : $runner $*"
echo "TAP receipt : $results"

cd "$TESTS_DIR"
# /ErrorStdOut turns a load-time error into stderr and a non-zero exit instead
# of a modal dialog nobody can dismiss under Xvfb. It must precede the script.
status=0
wine "$ahk" /ErrorStdOut "$runner" "$@" || status=$?

echo "AHK exit code: $status"
exit "$status"
