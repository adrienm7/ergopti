#!/usr/bin/env bash
# Record the macOS text-input agents around a native keyboard-source fixture.
#
# A refused TISSelectInputSource observation on a hosted runner follows a
# "TSMSendMessageToUIServer: CFMessagePortSendRequest FAILED(-1) to send to
# port com.apple.tsm.uiserver" line (run 42014901978, Intel macOS 15): the
# process that applies the selection did not answer. This snapshot names the
# launchd state, the run count, the last exit and any crash report of each
# text-input agent, so a failed receipt says whether that server died, was
# respawn-throttled, or stayed up. It only reads; each probe's own exit status
# is written next to its output and never changes the caller's verdict.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: $0 <output-file> <phase>" >&2; exit 64; }
output="$1"
phase="$2"
test "$(uname -s)" = Darwin || { echo "text-input agent snapshot needs macOS" >&2; exit 1; }
domain="gui/$(id -u)"
{
  printf 'phase=%s now_epoch=%s machine=%s\n' "$phase" "$(date +%s)" "$(uname -m)"
  sw_vers
  for label in com.apple.TextInputMenuAgent com.apple.TextInputSwitcher com.apple.SystemUIServer.agent; do
    printf '\n## %s/%s\n' "$domain" "$label"
    set +e
    launchctl print "$domain/$label" 2>&1 | grep -E '^\s*(state|pid|runs|last exit code|last terminating signal|spawn type|immediate reason)\b'
    statuses=("${PIPESTATUS[@]}")
    set -e
    printf 'launchctl_status=%s\n' "${statuses[0]}"
  done
  printf '\n## processes\n'
  set +e
  pgrep -lU "$(id -u)" -f 'TextInputMenuAgent|TextInputSwitcher|SystemUIServer'
  printf 'pgrep_status=%s\n' "$?"
  set -e
  printf '\n## crash reports\n'
  for directory in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
    if [ -d "$directory" ]; then
      find "$directory" -maxdepth 1 -type f \( -iname '*TextInput*' -o -iname '*SystemUIServer*' \) -print
    else
      printf 'absent: %s\n' "$directory"
    fi
  done
  printf '\n## unified log (text input, last 15 minutes, newest 200 lines)\n'
  set +e
  log show --last 15m --style compact \
    --predicate 'process CONTAINS "TextInput" OR eventMessage CONTAINS "tsm.uiserver" OR (process == "launchd" AND eventMessage CONTAINS "TextInput")' \
    2>&1 | tail -n 200
  statuses=("${PIPESTATUS[@]}")
  set -e
  printf 'log_status=%s\n' "${statuses[0]}"
} >> "$output"
