#!/usr/bin/env bash
# A fixed Swift invocation records its own status through the caller's held FD.
set -uo pipefail
test "$#" -eq 1 || exit 1
test "$(uname -s)" = Darwin || exit 1
test -d "$1" || exit 1
set +e
swift test -c debug --package-path static/ergopti_plus/macos/launcher \
  --scratch-path "$1" \
  --filter '(^|[.])KarabinerLeaseWorkerTests[/.]testRealInnerSilenceExitZeroBecomesOuterFailureAfterReady$'
swift_status=$?
printf '%s\n' "$swift_status" >&3 || exit 1
exit "$swift_status"
