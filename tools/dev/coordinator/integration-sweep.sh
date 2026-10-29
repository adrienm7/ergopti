#!/usr/bin/env bash
# tools/dev/coordinator/integration-sweep.sh

# ==============================================================================
# MODULE: Integration sweep
# DESCRIPTION:
# Runs the local gates a coordinator runs before fast-forwarding dev with an
# integration batch: gen:check, the format check, every single-file node check
# of the feature suites (in parallel, each red one re-run alone to tell a flake
# from a failure), the Linux LuaJIT suite and the macOS Lua suite per group.
# It reports; it never changes the tree.
#
# USAGE:
#   bash tools/dev/coordinator/integration-sweep.sh <output-dir> [jobs]
#
# Pinned Ruff 0.15.8 and Node 22 must be first on PATH (the commit hook needs
# them too). As root, the known host-only reds of TODO.md
# ("Host-only reds") are expected; compare against them, never weaken a test.
# ==============================================================================

set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <output-dir> [jobs]" >&2; exit 64; }
OUT="$1"
JOBS="${2:-6}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$OUT" || exit 1
cd "$ROOT" || exit 1

echo "base $(git rev-parse --short=10 HEAD)"
npm run -s gen:check >/dev/null 2>&1 && echo "ok gen:check" || echo "FAIL gen:check"
node tools/lint/format.cjs --check >/dev/null 2>&1 && echo "ok format" || echo "FAIL format"

# A private HOME and runtime dir keep the checks off the real profile.
HOME_DIR="$(mktemp -d "$OUT/home.XXXX")"
XDG_RUNTIME_DIR="$(mktemp -d)"
export XDG_RUNTIME_DIR
chmod 700 "$XDG_RUNTIME_DIR"

jq -r '.checks[] | select(.cmd|test("NODE|node")) | select(.args|length==1) | .args[0]' \
	tools/test/features/*/suite.json | sort -u > "$OUT/node-checks.txt"
HOME="$HOME_DIR" xargs -P"$JOBS" -I{} sh -c 'timeout 900 node {} >/dev/null 2>&1 || echo "{}"' \
	< "$OUT/node-checks.txt" | sort > "$OUT/node-reds.txt"
echo "node checks red under load:"
while IFS= read -r check; do
	if HOME="$HOME_DIR" timeout 900 node "$check" > "$OUT/red-$(basename "$check").log" 2>&1; then
		echo "  flaky-ok $check"
	else
		echo "  RED $check"
	fi
done < "$OUT/node-reds.txt"

(cd static/ergopti_plus/linux && HOME="$HOME_DIR" timeout 2400 luajit tests/run.lua > "$OUT/linux.log" 2>&1)
echo "linux:"
grep -E '^  - ' "$OUT/linux.log" | cut -c1-140

# One process per group: a single macOS suite process slows down progressively.
cd static/ergopti_plus/macos || exit 1
for group in meta core modules menu_llm menu_input ui other integration; do
	HOME="$(mktemp -d "$OUT/home.XXXX")" timeout 1500 lua tests/run.lua --module="$group" > "$OUT/mac-$group.log" 2>&1
	echo "mac $group rc=$? $(grep -E '^Passed|^Failed' "$OUT/mac-$group.log" | tr '\n' ' ')"
	sed -n '/DETAILED FAILURES/,$p' "$OUT/mac-$group.log" | grep -E '^\[[0-9]+\]' | cut -c1-140
done
