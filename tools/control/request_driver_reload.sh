#!/bin/sh
# tools/control/request_driver_reload.sh
#
# Asks the running macOS or Linux driver to reload, and reports requested,
# refused and completed separately.
#
# Reads the session the driver published in its private control folder, writes
# one request carrying the session token, then rings the driver: on Linux with
# SIGUSR1 (only the same user may send it), on macOS through the folder watcher
# the request file itself wakes. The driver hands the request to its own reload
# owner. This script never starts a driver, never ends one and never retries: a
# reload that stays "requested" past the timeout has an unknown outcome. The
# declaration is static/ergopti_plus/_shared/modules/control/driver_control.json;
# the folders and file names below must match it (the Linux suite checks them).
#
# Usage: sh tools/control/request_driver_reload.sh [timeout_seconds]
# Exit codes: 0 completed, 1 refused, 2 still requested at the timeout, 3 no
# reachable driver.

set -eu

timeout_seconds=${1:-60}
case "$timeout_seconds" in
	'' | *[!0-9]*) echo "timeout must be a whole number of seconds" >&2; exit 64 ;;
esac

case "$(uname -s)" in
	Darwin) folder="$HOME/Library/Application Support/ergopti_plus/control" ;;
	Linux)
		if [ -z "${XDG_RUNTIME_DIR:-}" ]; then echo "XDG_RUNTIME_DIR is not set" >&2; exit 3; fi
		folder="$XDG_RUNTIME_DIR/ergopti_plus/control"
		;;
	*) echo "unsupported system: $(uname -s)" >&2; exit 64 ;;
esac

session="$folder/session.json"
request="$folder/reload.request"
result="$folder/reload.result"

if [ ! -f "$session" ]; then
	echo '{"state":"unreachable","detail":"no driver session is published"}'
	exit 3
fi
# The driver writes the session as one canonical line.
pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$session")
token=$(sed -n 's/.*"token":"\([0-9a-f]\{64\}\)".*/\1/p' "$session")
driver=$(sed -n 's/.*"driver":"\([a-z]*\)".*/\1/p' "$session")
if [ -z "$pid" ] || [ -z "$token" ] || [ -z "$driver" ]; then
	echo "the driver session is malformed" >&2
	exit 64
fi
if ! kill -0 "$pid" 2>/dev/null; then
	printf '{"state":"unreachable","detail":"the published driver process is gone","driver_pid":%s}\n' "$pid"
	exit 3
fi

request_id="sh-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
umask 077
stage="$request.tmp-$$"
printf '{"schema":1,"token":"%s","request_id":"%s"}' "$token" "$request_id" > "$stage"
mv -f "$stage" "$request"
if [ "$driver" = "linux" ]; then
	if ! kill -USR1 "$pid" 2>/dev/null; then
		rm -f "$request"
		printf '{"request_id":"%s","state":"refused","reason":"endpoint","driver_pid":%s}\n' "$request_id" "$pid"
		exit 1
	fi
fi

deadline=$(( $(date +%s) + timeout_seconds ))
last=""
while [ "$(date +%s)" -lt "$deadline" ]; do
	if [ -f "$result" ] && grep -q "\"request_id\":\"$request_id\"" "$result" 2>/dev/null; then
		last=$(cat "$result")
		case "$last" in
			*'"state":"completed"'*) printf '%s\n' "$last"; exit 0 ;;
			*'"state":"refused"'*) printf '%s\n' "$last"; exit 1 ;;
			*'"state":"timeout"'*) printf '%s\n' "$last"; exit 2 ;;
			*'"state":"requested"'*'"successor_pid":null'*)
				# A restart that cannot name its successor leaves a pending record with a
				# deadline: past it, the answer is a timeout and never a completion.
				pending_deadline=$(printf '%s' "$last" | sed -n 's/.*"deadline":\([0-9][0-9]*\).*/\1/p')
				if [ -n "$pending_deadline" ] && [ "$(date +%s)" -gt "$pending_deadline" ]; then
					printf '{"request_id":"%s","state":"timeout","reason":"deadline","driver_pid":%s}\n' "$request_id" "$pid"
					exit 2
				fi
				;;
		esac
	fi
	sleep 0.2 2>/dev/null || sleep 1
done
if [ -n "$last" ]; then
	printf '%s\n' "$last"
else
	printf '{"request_id":"%s","state":"unknown","driver_pid":%s}\n' "$request_id" "$pid"
fi
exit 2
