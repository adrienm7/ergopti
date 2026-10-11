#!/usr/bin/env bash
# tools/diagnostics/run_lease_silence_native.sh
# Executes only the real DEBUG paired-process control, with no Karabiner effects.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'LEASE_SILENCE_XCTEST architecture argument refused.' >&2
  exit 1
fi
architecture="$1"
case "$architecture" in
  arm64) expected_machine=arm64 ;;
  amd64) expected_machine=x86_64 ;;
  *) echo 'LEASE_SILENCE_XCTEST architecture refused.' >&2; exit 1 ;;
esac
test "$(uname -s)" = Darwin
test "$(uname -m)" = "$expected_machine"
test "${GITHUB_ACTIONS:-}" = true
test "${GITHUB_EVENT_NAME:-}" = workflow_dispatch
test "${ERGOPTI_DEV_RELEASE_RELEASE:-}" = false
test -z "${ERGOPTI_DEV_QUALIFICATION_PROFILE:-}"
test -n "${RUNNER_TEMP:-}"
test -n "${GITHUB_SHA:-}"
test -n "${GITHUB_RUN_ID:-}"
test -n "${GITHUB_RUN_ATTEMPT:-}"

umask 077
evidence="$RUNNER_TEMP/lease-silence-native"
mkdir -m 700 "$evidence"
scratch="$(mktemp -d "$RUNNER_TEMP/lease-silence-swift.XXXXXX")"
judge=tools/diagnostics/lease_silence_xctest_evidence.cjs
source_receipt="$evidence/source.json"
transcript="$evidence/xctest.log"
direct_status="$evidence/swift-status.txt"
node "$judge" begin "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" \
  "$architecture" "$source_receipt"
export SWIFT_BACKTRACE=enable=yes
set -C
exec 3> "$direct_status"
set +C
set +e
script -q /dev/null /bin/bash tools/diagnostics/lease_silence_swift_child.sh "$scratch" \
  2>&1 | tee "$transcript"
statuses=("${PIPESTATUS[@]}")
set -e
exec 3>&-
test "${#statuses[@]}" -eq 2
set -C
printf '%s\n' "${statuses[0]}" > "$evidence/script-status.txt"
printf '%s\n' "${statuses[1]}" > "$evidence/capture-status.txt"
set +C
node "$judge" judge "$transcript" "$direct_status" "${statuses[0]}" "${statuses[1]}" \
  "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$architecture" \
  "$source_receipt" "$evidence/verdict.json"
