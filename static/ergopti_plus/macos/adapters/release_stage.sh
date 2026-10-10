#!/bin/sh
# adapters/release_stage.sh
#
# Downloads and verifies one declared release archive inside its owned stage.
# The caller supplies URL, SHA-256, stage, version, running app, format and
# bundle basename as arguments. Native verification precedes READY; this script
# never swaps or launches an application.

set -u
[ "$#" -eq 7 ] || exit 20
url=$1; digest=$2; dir=$3; version=$4; running=$5; format=$6; bundle=$7
case "$format" in
	zip|tar.xz) ;;
	*) exit 20 ;;
esac
case "$bundle" in
	""|"."|".."|*/*) exit 20 ;;
esac
case "$bundle" in
	?*.app) ;;
	*) exit 20 ;;
esac
umask 077
# A timestamp collision must not reuse an earlier archive or app.
/bin/mkdir "$dir" || exit 10
archive="$dir/release.$format"
# Preserve curl's explicit environment route, including its bypass semantics.
# A production request without an explicit route uses the bundled native owner.
explicit_route="${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}"
if [ -n "$explicit_route" ] || [ "${ERGOPTI_RELEASE_STAGE_REQUEST+present}" != present ]; then
	/usr/bin/curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
		--max-time 900 --output "$archive" "$url" || exit 10
else
	launcher="${ERGOPTI_LAUNCHER_EXECUTABLE:-}"
	expected="${ERGOPTI_LAUNCHER_DEVICE:-}:${ERGOPTI_LAUNCHER_INODE:-}"
	# Reuse the launcher's existing bundle/path/device/inode admission. These
	# observations refuse a visible replacement; they do not close an ABA race.
	launcher_current() {
		[ "$launcher" = "$running/Contents/MacOS/ErgoptiPlus" ] || return 1
		[ -f "$launcher" ] && [ -x "$launcher" ] && [ ! -L "$launcher" ] || return 1
		identity=$(/usr/bin/stat -f '%d:%i' "$launcher" 2>/dev/null) || return 1
		[ "$identity" = "$expected" ]
	}
	launcher_current || exit 10
	[ -d "$dir" ] && [ ! -L "$dir" ] || exit 10
	stage_identity=$(/usr/bin/stat -f '%d:%i' "$dir") || exit 10
	request_file="$dir/download-request.json"
	printf '%s\n' "$ERGOPTI_RELEASE_STAGE_REQUEST" > "$request_file" || exit 10
	request_bytes=$(/usr/bin/stat -f '%z' "$request_file") || exit 10
	case "$request_bytes" in ""|*[!0-9]*) exit 10 ;; esac
	[ "$request_bytes" -le 65536 ] || exit 10
	# Independent argv bindings prevent a foreign request from publishing at a
	# different destination. The native parser owns the full typed JSON schema.
	field=$(/usr/bin/plutil -extract version raw -o - "$request_file") || exit 10
	[ "$field" = 1 ] || exit 10
	field=$(/usr/bin/plutil -extract url raw -o - "$request_file") || exit 10
	[ "$field" = "$url" ] || exit 10
	field=$(/usr/bin/plutil -extract sha256 raw -o - "$request_file") || exit 10
	[ "$field" = "$digest" ] || exit 10
	field=$(/usr/bin/plutil -extract output raw -o - "$request_file") || exit 10
	[ "$field" = "$archive" ] || exit 10
	field=$(/usr/bin/plutil -extract timeout_ms raw -o - "$request_file") || exit 10
	[ "$field" = 900000 ] || exit 10
	receipt_file="$dir/download-receipt.json"
	# Foreground execution retains the original shell task's completion behavior.
	# The CLI owns its single 900-second budget, EOF, network and spool closure.
	"$launcher" --managed-bootstrap-download 900000 < "$request_file" > "$receipt_file"
	native_status=$?
	launcher_current || exit 10
	[ -d "$dir" ] && [ ! -L "$dir" ] || exit 10
	[ "$(/usr/bin/stat -f '%d:%i' "$dir")" = "$stage_identity" ] || exit 10
	[ -f "$receipt_file" ] && [ ! -L "$receipt_file" ] || exit 10
	receipt_bytes=$(/usr/bin/stat -f '%z' "$receipt_file") || exit 10
	case "$receipt_bytes" in ""|*[!0-9]*) exit 10 ;; esac
	[ "$receipt_bytes" -le 128 ] || exit 10
	IFS= read -r receipt < "$receipt_file" || exit 10
	# read must observe the original LF; byte length excludes any further
	# bytes, including NUL. Exact forms exclude foreign/duplicate keys and types.
	[ "$receipt_bytes" -eq "$((${#receipt} + 1))" ] || exit 10
	accepted_reason=""
	for reason in complete protocol deadline cancelled offline certificate connect unavailable proxy content_encoding http verify file_create file_write file_publish cleanup; do
		if [ "$reason" = complete ]; then success=true; else success=false; fi
		# JSONSerialization currently leaves dictionary key order unspecified.
		case "$receipt" in
			"{\"version\":1,\"success\":$success,\"reason\":\"$reason\"}"|\
			"{\"version\":1,\"reason\":\"$reason\",\"success\":$success}"|\
			"{\"success\":$success,\"version\":1,\"reason\":\"$reason\"}"|\
			"{\"success\":$success,\"reason\":\"$reason\",\"version\":1}"|\
			"{\"reason\":\"$reason\",\"version\":1,\"success\":$success}"|\
			"{\"reason\":\"$reason\",\"success\":$success,\"version\":1}") accepted_reason=$reason; break ;;
		esac
	done
	case "$native_status:$accepted_reason" in
		0:complete) ;;
		74:verify) exit 21 ;;
		75:deadline|74:protocol|74:cancelled|74:offline|74:certificate|74:connect|74:unavailable|74:proxy|74:content_encoding|74:http|74:file_create|74:file_write|74:file_publish|74:cleanup) exit 10 ;;
		*) exit 10 ;;
	esac
fi
actual=$(/usr/bin/shasum -a 256 "$archive") || exit 20
actual=${actual%% *}
[ "$actual" = "$digest" ] || exit 21
case "$format" in
	zip)
		/usr/bin/ditto -x -k "$archive" "$dir/app" || exit 22
		;;
	tar.xz)
		/bin/mkdir -p "$dir/app" || exit 22
		/usr/bin/tar -xJpf "$archive" -C "$dir/app" || exit 22
		;;
esac
app="$dir/app/$bundle"
[ -d "$app" ] || exit 23
found=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") || exit 24
[ "$found" = "$version" ] || exit 25
# Display owns both output streams and its true exit status, before parsing.
displayed=$(/usr/bin/codesign -d -r- "$running" 2>&1) || exit 26
# Native codesign can comment a displayed designation with the fixed "# "
# prefix. Count both observed forms before substitution can erase empty lines.
designations=$(printf '%s\n' "$displayed" | /usr/bin/sed -n '/^designated => /s/.*/x/p; /^# designated => /s/.*/x/p') || exit 26
[ "$designations" = x ] || exit 26
requirement=$(printf '%s\n' "$displayed" | /usr/bin/sed -n 's/^# designated => /designated => /; s/^designated => //p') || exit 26
[ -n "$requirement" ] || exit 26
case "$requirement" in
	*'
'*) exit 26 ;;
esac
/usr/bin/codesign --verify --deep --strict -R "=$requirement" "$app" || exit 27
printf 'READY %s\n' "$app"
