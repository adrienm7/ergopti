#!/bin/sh
set -eu
tool=$1
client_shell=${2:-sh}
dir=$(mktemp -d)
daemon=
cleanup() {
	[ -z "$daemon" ] || kill "$daemon" 2>/dev/null || :
	rm -rf "$dir"
}
trap cleanup EXIT
folder="$dir/ergopti/control"
mkdir -p "$folder"
cat > "$dir/daemon.sh" <<'EOF'
#!/bin/sh
trap 'id=$(sed -n '\''s/.*"request_id":"\([^"]*\)".*/\1/p'\'' "$1/reload.request"); printf '\''{"request_id":"%s","state":"completed"}\n'\'' "$id" > "$1/reload.result"' USR1
: > "$2"
while :; do sleep 0.05; done
EOF
sh "$dir/daemon.sh" "$folder" "$dir/ready" &
daemon=$!
while [ ! -e "$dir/ready" ]; do kill -0 "$daemon"; done
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '{"pid":%s,"token":"%s","driver":"linux"}\n' "$daemon" "$token" > "$folder/session.json"
set +e
XDG_RUNTIME_DIR="$dir" timeout 3 "$client_shell" "$tool" 08 > "$dir/output" 2>&1
code=$?
set -e
[ "$code" -eq 0 ] || { cat "$dir/output" >&2; exit 1; }
grep -q '"state":"completed"' "$dir/output"
rm -f "$folder/reload.request" "$folder/reload.result"
# A large but representable deadline is valid; leave a ten-second margin for
# the wall clock to advance between the fixture and the client preflight.
large=$((9223372036854775807 - $(date +%s) - 10))
set +e
XDG_RUNTIME_DIR="$dir" timeout 3 "$client_shell" "$tool" "$large" > "$dir/output" 2>&1
code=$?
set -e
[ "$code" -eq 0 ] || { cat "$dir/output" >&2; exit 1; }
grep -q '"state":"completed"' "$dir/output"
rm -f "$folder/reload.request" "$folder/reload.result" "$folder/.reload-client.lock"
for invalid in 9223372036854775807 18446744073709551616 18446744073709551617 999999999999999999999999999999999; do
	set +e
	XDG_RUNTIME_DIR="$dir" timeout 3 "$client_shell" "$tool" "$invalid" > "$dir/output" 2>&1
	code=$?
	set -e
	[ "$code" -eq 64 ] || { printf 'overflow returned %s\n' "$code" >&2; cat "$dir/output" >&2; exit 1; }
	# Give a wrongly sent SIGUSR1 time to make the real receiver publish.
	sleep 0.3
	[ ! -e "$folder/reload.request" ]
	[ ! -e "$folder/reload.result" ]
	[ ! -e "$folder/.reload-client.lock" ]
done
