#!/usr/bin/env bash
# Run the owned virtual-HID daemon-report XCTest cohort on this runner's own architecture.
#
# The full launcher suite runs these classes only on the Apple silicon macOS 26
# cell, so the Intel cell never compiled or executed the report decoder, its
# main-operation routing or its worker refusals. This cohort runs the same four
# classes in both managed-ollama-native cells and requires every case by name
# count: a renamed, skipped or missing class fails instead of passing on fewer.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: $0 <arm64|amd64> <build-root>" >&2; exit 64; }
architecture="$1"
root="$2"
test "$(uname -s)" = Darwin || { echo "daemon-report cohort needs macOS" >&2; exit 1; }
case "$architecture" in
  arm64) expected_machine=arm64 ;;
  amd64) expected_machine=x86_64 ;;
  *) echo "unknown architecture: $architecture" >&2; exit 64 ;;
esac
test "$(uname -m)" = "$expected_machine" || { echo "runner is $(uname -m), cell is $architecture" >&2; exit 1; }
test -d "$root" || { echo "missing build root: $root" >&2; exit 1; }
transcript="$root/daemon-report-xctest.log"
classes=(
  OwnedVirtualHIDDaemonReportTests:13
  OwnedVirtualHIDDaemonReportMainOperationTests:13
  OwnedVirtualHIDDaemonReportPurposeQueryTests:4
  OwnedVirtualHIDDaemonReportWorkerTests:3
)
total=33
set +e
swift test --package-path static/ergopti_plus/macos/launcher \
  --scratch-path "$root/swift" \
  --filter '(^|[.])(OwnedVirtualHIDDaemonReportTests|OwnedVirtualHIDDaemonReportMainOperationTests|OwnedVirtualHIDDaemonReportPurposeQueryTests|OwnedVirtualHIDDaemonReportWorkerTests)([/.]|$)' \
  2>&1 | tee "$transcript"
statuses=("${PIPESTATUS[@]}")
set -e
test "${#statuses[@]}" -eq 2
test "${statuses[0]}" -eq 0 || { echo "::error::daemon-report XCTest exited ${statuses[0]}"; exit 1; }
test "${statuses[1]}" -eq 0 || { echo "::error::daemon-report transcript capture exited ${statuses[1]}"; exit 1; }
if grep -Eq "^Test Case.* skipped|with [1-9][0-9]* tests? skipped" "$transcript"; then
  echo "::error::daemon-report XCTest skipped a mandatory case"
  exit 1
fi
for entry in "${classes[@]}"; do
  class="${entry%:*}"
  count="${entry##*:}"
  grep -Fq "Test Suite '$class' passed" "$transcript" || { echo "::error::$class did not pass"; exit 1; }
  passed="$(grep -Ec "^Test Case '-\[ErgoptiPlusTests\.$class test[A-Za-z0-9_]*\]' passed" "$transcript")"
  test "$passed" -eq "$count" || { echo "::error::$class passed $passed of $count cases"; exit 1; }
done
grep -Fq "Executed $total tests, with 0 failures" "$transcript" || { echo "::error::daemon-report cohort did not execute $total cases"; exit 1; }
echo "::notice title=Daemon-report XCTest::architecture=$architecture classes=${#classes[@]} passed=$total/$total"
