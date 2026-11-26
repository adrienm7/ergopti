#!/bin/sh
set -eu
tool=$1
dir=$(mktemp -d)
daemon=
first=
cleanup() {
	[ -z "$first" ] || kill "$first" 2>/dev/null || :
	[ -z "$daemon" ] || kill "$daemon" 2>/dev/null || :
	rm -rf "$dir"
}
trap cleanup EXIT
mkdir -p "$dir/ergopti/control"
sh -c 'trap "" USR1; : > "$1"; while :; do sleep 1; done' sh "$dir/ready" &
daemon=$!
while [ ! -e "$dir/ready" ]; do kill -0 "$daemon"; done
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
folder="$dir/ergopti/control"
printf '{"pid":%s,"token":"%s","driver":"linux"}\n' "$daemon" "$token" > "$folder/session.json"
XDG_RUNTIME_DIR="$dir" sh "$tool" 10 > "$dir/first.out" 2>&1 &
first=$!
while [ ! -f "$folder/reload.request" ]; do kill -0 "$first"; done
cp "$folder/reload.request" "$dir/original"
set +e
XDG_RUNTIME_DIR="$dir" sh "$tool" 1 > "$dir/second.out" 2>&1
code=$?
set -e
[ "$code" -eq 1 ]
grep -q '"reason":"busy"' "$dir/second.out"
original_hash=$(sha256sum "$dir/original")
current_hash=$(sha256sum "$folder/reload.request")
[ "${original_hash%% *}" = "${current_hash%% *}" ]
kill -KILL "$first"
wait "$first" 2>/dev/null || :
first=
# A killed waiting client must not leave a permanent stale lock. Its short
# polling subprocess may still hold the descriptor until that subprocess exits.
sleep 1
set +e
XDG_RUNTIME_DIR="$dir" sh "$tool" 0 > "$dir/third.out" 2>&1
code=$?
set -e
[ "$code" -eq 2 ]
grep -q '"state":"unknown"' "$dir/third.out"
current_hash=$(sha256sum "$folder/reload.request")
[ "${original_hash%% *}" != "${current_hash%% *}" ]
