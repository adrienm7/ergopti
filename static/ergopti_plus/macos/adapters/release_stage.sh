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
/bin/mkdir -p "$dir" || exit 10
archive="$dir/release.$format"
/usr/bin/curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
	--max-time 900 --output "$archive" "$url" || exit 10
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
