#!/bin/sh
set -eu
tool=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
folder="$dir/ergopti/control"
mkdir -p "$folder"
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '{"pid":%s,"token":"%s","driver":"linux"}\n' "$$" "$token" > "$folder/session.json"
lock="$folder/.reload-client.lock"
printf 'untouched\n' > "$dir/target"
for kind in fifo symlink directory; do
	case "$kind" in
		fifo) mkfifo "$lock" ;;
		symlink) ln -s "$dir/target" "$lock" ;;
		directory) mkdir "$lock" ;;
	esac
	set +e
	XDG_RUNTIME_DIR="$dir" timeout 2 sh "$tool" 0 > "$dir/output" 2>&1
	code=$?
	set -e
	[ "$code" -eq 3 ] || { printf '%s returned %s\n' "$kind" "$code" >&2; exit 1; }
	[ ! -e "$folder/reload.request" ]
	case "$kind" in
		fifo) [ -p "$lock" ]; rm "$lock" ;;
		symlink) [ -L "$lock" ]; rm "$lock" ;;
		directory) [ -d "$lock" ]; rmdir "$lock" ;;
	esac
	[ "$(cat "$dir/target")" = untouched ]
done

# Replace the pathname after the descriptor was actually locked. The client
# must not claim exclusion on the now-unlinked inode.
: > "$lock"
printf 'replacement\n' > "$dir/replacement"
mkdir "$dir/bin"
cat > "$dir/bin/flock" <<'EOF'
#!/bin/sh
"$REAL_FLOCK" "$@" || exit $?
mv -f "$LOCK_REPLACEMENT" "$LOCK_PATH"
EOF
chmod +x "$dir/bin/flock"
real_flock=$(command -v flock)
set +e
REAL_FLOCK="$real_flock" LOCK_REPLACEMENT="$dir/replacement" LOCK_PATH="$lock" \
	PATH="$dir/bin:$PATH" XDG_RUNTIME_DIR="$dir" timeout 2 sh "$tool" 0 > "$dir/output" 2>&1
code=$?
set -e
[ "$code" -eq 3 ] || { printf 'replaced lock returned %s\n' "$code" >&2; exit 1; }
[ "$(cat "$lock")" = replacement ]
[ ! -e "$folder/reload.request" ]

# A shell redirection failure must remain catchable under the installed /bin/sh.
# The small inline form avoids needing an extra descriptor to read this script.
set +e
timeout 2 sh -c 'ulimit -n 8; if ! { command exec 8<>/dev/null; } 2>/dev/null; then exit 3; fi; exit 9' > "$dir/output" 2>&1
code=$?
set -e
[ "$code" -eq 3 ] || { printf 'descriptor refusal returned %s\n' "$code" >&2; cat "$dir/output" >&2; exit 1; }
[ ! -e "$folder/reload.request" ]
