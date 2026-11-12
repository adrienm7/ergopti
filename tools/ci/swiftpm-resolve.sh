#!/usr/bin/env bash
# Resolve one SwiftPM package's dependencies with a bounded retry.
#
# A hosted macOS runner once failed to clone Sparkle from github.com
# (« could not read Username for 'https://github.com': terminal prompts
# disabled ») while the other architecture's identical lot resolved it. The
# clone is the only network step of the build that follows, so it alone is
# retried: at most MAX_ATTEMPTS times, DELAY_SECONDS apart. Every failed attempt
# is reported (a warning while another attempt remains, an error for the last),
# and the step fails after the last one. A later
# `swift build` with the same scratch path then reuses the resolved checkouts.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: $0 <package-path> <scratch-path>" >&2; exit 64; }
package_path="$1"
scratch_path="$2"
test -d "$package_path" || { echo "missing package path: $package_path" >&2; exit 1; }

# Three attempts cover a transient refusal without hiding a lasting one.
MAX_ATTEMPTS=3
# Long enough for a throttled or briefly unreachable host to recover.
DELAY_SECONDS=20

attempt=1
while :; do
  echo "SwiftPM resolve attempt $attempt/$MAX_ATTEMPTS for $package_path."
  status=0
  swift package resolve --package-path "$package_path" --scratch-path "$scratch_path" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "SwiftPM resolve succeeded on attempt $attempt/$MAX_ATTEMPTS."
    exit 0
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::error::SwiftPM resolve attempt $attempt/$MAX_ATTEMPTS failed with status $status; the lot stops here."
    exit "$status"
  fi
  echo "::warning::SwiftPM resolve attempt $attempt/$MAX_ATTEMPTS failed with status $status; retrying in ${DELAY_SECONDS} s."
  attempt=$((attempt + 1))
  sleep "$DELAY_SECONDS"
done
