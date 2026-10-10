set -uo pipefail
umask 077
test ! -e "$2" && test ! -L "$2" || exit 1
set +e
swift test --package-path static/ergopti_plus/macos/launcher \
  --scratch-path "$1" \
  --filter 'KarabinerLeaseWorkerTests|LeaseDiagnosticNextObservationTests'
lease_child_status=$?
set -eC
printf '%s\n' "$lease_child_status" > "$2"
exit "$lease_child_status"
