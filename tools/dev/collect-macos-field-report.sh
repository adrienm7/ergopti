#!/usr/bin/env bash
# tools/dev/collect-macos-field-report.sh

# ==============================================================================
# MODULE: macOS field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Mac: it updates the field
# branch from dev, gathers the evidence the coordinator reads (today's
# ErgoptiPlus logs, the boot and slow-segment lines, system and toolchain
# facts, the input-source probe), stores it under docs/field-reports/, then
# commits and pushes the branch. The logs are gitignored, so they are added with
# `git add -f`; the logger already masks secrets, the home folder, e-mail
# addresses and personal names, and the summary lists every file it adds.
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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "$PWD")"
REPO_ROOT="${REPO_ROOT%.}"
LOG_DIR="$HOME/Library/Logs/ergopti_plus"
FIELD_BRANCH_PREFIX="field/"

fail() { printf '[field-report] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[field-report] %s\n' "$*"; }

push=true
case "$#:${1:-}" in
	0:) ;;
	1:--no-push) push=false ;;
	*) fail "Expected no argument or --no-push." ;;
esac

[ "$(uname -s)" = "Darwin" ] || fail "This collector runs on macOS only."
cd "$REPO_ROOT" || fail "Cannot enter the repository root."
git rev-parse --git-dir >/dev/null 2>&1 || fail "Not inside the Ergopti clone."

branch="$(git branch --show-current)"
case "$branch" in
	"$FIELD_BRANCH_PREFIX"*) ;;
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
	git fetch -q --depth "$depth" origin dev || fail "git fetch of dev failed."
	dev_head="$(git rev-parse FETCH_HEAD)" || fail "Cannot read the fetched dev head."
	git merge-base HEAD "$dev_head" >/dev/null 2>&1 && break
	[ "$depth" -lt 3200 ] || fail "No common history with dev within $depth commits; re-clone with --depth 1."
	depth=$((depth * 4))
done
git merge --ff-only "$dev_head" >/dev/null 2>&1 \
	|| git merge --no-edit "$dev_head" \
	|| fail "Could not bring dev into $branch; resolve the merge and run again."

stamp="$(date +%Y-%m-%d_%H%M%S)"
out="docs/field-reports/mac-$stamp"
mkdir -p "$out" || fail "Cannot create $out."
steps="$out/steps.txt"
: > "$steps"

# Runs one named step, captures its output into a file and records its status.
step() {
	local name="$1"; shift
	local file="$out/$name.txt"
	"$@" > "$file" 2>&1
	local status=$?
	printf '%-28s exit=%s\n' "$name" "$status" >> "$steps"
	[ "$status" -eq 0 ] || log "step '$name' exited $status (kept in $file)"
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
step user_layouts sh -c 'ls -la "$HOME/Library/Keyboard Layouts" 2>&1'

# ===========================================
# ======= 3/ Input-source probe =============
# ===========================================

probe_src="tools/diagnostics/macos_tis_register_probe.swift"
# A unique binary per run: a failed build must never leave an older probe to run.
probe_bin="/tmp/ep_tis_probe_${stamp}"
if [ -f "$probe_src" ]; then
	step probe_compile swiftc -O -o "$probe_bin" "$probe_src"
	if [ -x "$probe_bin" ]; then
		# Plain run, then the driver's own enabling route (writes and restores
		# com.apple.HIToolbox, restarts SystemUIServer), then a layout added
		# inside the enabled Ergopti bundle (backed up and restored).
		step probe_run "$probe_bin"
		step probe_write_prefs "$probe_bin" --write-prefs
		step probe_replace_ergopti "$probe_bin" --replace-ergopti --write-prefs
		rm -f "$probe_bin"
	else
		printf '%-28s skipped (the probe did not compile)\n' "probe_runs" >> "$steps"
	fi
fi

# ===========================================
# ======= 4/ Logs and their digest ==========
# ===========================================

today="$(date +%Y-%m-%d)"
if [ -d "$LOG_DIR" ]; then
	for f in "$LOG_DIR"/ErgoptiPlus_"$today".log "$LOG_DIR"/ErgoptiPlus_errors_"$today".log \
		"$LOG_DIR"/ErgoptiPlus_llm.log "$LOG_DIR"/launcher.log; do
		[ -f "$f" ] && cp "$f" "$out/" && printf '%-28s copied\n' "$(basename "$f")" >> "$steps"
	done
	day="$LOG_DIR/ErgoptiPlus_$today.log"
	if [ -f "$day" ]; then
		step digest_boot grep -E "Boot complete|Boot CPU|Boot stage completed|held the main thread" "$day"
		step digest_slow grep -E "\[HotPath\]|Slow " "$day"
		step digest_errors grep -E "\[(ERROR|WARNING)\]" "$day"
		step digest_input grep -E "key_event_health|karabiner.lease|guardian" "$day"
	fi
else
	printf '%-28s missing\n' "logs" >> "$steps"
fi

# ===========================================
# ======= 5/ Commit and push ================
# ===========================================

log "Collected into $out:"
ls -1 "$out" | sed 's/^/  /'
git add -f -- "$out" || fail "git add of $out failed."
git commit -q -m "docs(field): macOS field report $stamp" -- "$out" || fail "git commit failed."
if [ "$push" = true ]; then
	git push -u origin HEAD || fail "git push failed; run 'git push -u origin HEAD' by hand."
	log "Pushed $branch. Tell the coordinator: report $out."
else
	log "Committed on $branch without pushing."
fi
