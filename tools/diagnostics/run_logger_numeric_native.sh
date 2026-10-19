#!/usr/bin/env bash
# Own only the three numeric logger tests; historical and package gates stay mandatory.
set -euo pipefail
test "$#" -eq 5 || exit 1
candidate="$1"
run_id="$2"
attempt="$3"
architecture="$4"
root="$5"
test "$(uname -s)" = Darwin || exit 1
case "$architecture" in
  arm64) expected_machine=arm64 ;;
  amd64) expected_machine=x86_64 ;;
  *) exit 1 ;;
esac
test "$(uname -m)" = "$expected_machine" || exit 1
test -d "$root" || exit 1
transcript="$root/logger-numeric-3-xctest.log"
source="$root/logger-numeric-3-source.json"
verdict="$root/logger-numeric-3-verdict.json"
judge=tools/diagnostics/native_logger_numeric_xctest_evidence.cjs
node "$judge" begin "$candidate" "$run_id" "$attempt" "$architecture" "$source"
set +e
swift test --package-path static/ergopti_plus/macos/launcher \
  --scratch-path "$root/swift" \
  --filter '(^|[.])LoggerDatagramNumericTests([/.]|$)' 2>&1 | tee "$transcript"
statuses=("${PIPESTATUS[@]}")
set -e
test "${#statuses[@]}" -eq 2
node "$judge" judge "$transcript" "${statuses[0]}" "${statuses[1]}" \
  "$candidate" "$run_id" "$attempt" "$architecture" "$source" "$verdict"
