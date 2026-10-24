#!/bin/sh
# tools/build/appimage-distro-check.sh
#
# Runs inside one distribution container for appimage-distro-matrix.sh, in
# plain sh because Alpine has no bash. It reads the C library the image really
# has, independently of the AppImage's own preflight, decides what the AppImage
# must do there, and checks it:
#   - musl, or glibc older than the ceiling: --help is refused with the
#     preflight's exit status and a sentence on stderr;
#   - glibc at or above the ceiling: --help exits 0, and on an apt-based image
#     the argument-free desktop launch, as an unprivileged user under Xvfb,
#     maps its status window, docks its icon in stalonetray and quits from the
#     tray menu with no process left behind.
# The container has no keyboard, so the desktop launch is the no-keyboard
# state the AppImage catalogue also sees.
#
# Usage (from appimage-distro-matrix.sh only):
#   sh appimage-distro-check.sh <AppImage> <glibc ceiling> <refusal exit status>

set -eu

APPIMAGE="$1"
CEILING="$2"
REFUSAL_EXIT="$3"
LOG_DIR="$(mktemp -d)"

fail() {
	echo "[ERR] $*" >&2
	exit 1
}

# ----------------------------------------------------------------------
# 1. What the image's C library is
# ----------------------------------------------------------------------
if [ -e /lib/ld-musl-x86_64.so.1 ]; then
	expected=refuse
	libc=musl
else
	libc="$(ldd --version 2>&1 | head -n 1 | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\)[^ ]*$/\1/p')"
	[ -n "$libc" ] || fail "ENVIRONMENT: neither musl nor a glibc ldd version in this image."
	if [ "$(printf '%s\n%s\n' "$libc" "$CEILING" | sort -t . -k 1,1n -k 2,2n | head -n 1)" = "$CEILING" ]; then
		expected=run
	else
		expected=refuse
	fi
	libc="glibc $libc"
fi
echo "C library: $libc; the AppImage must $expected (ceiling glibc $CEILING)."

# ----------------------------------------------------------------------
# 2. A command-line launch, with no other package installed
# ----------------------------------------------------------------------
cp "$APPIMAGE" /tmp/ErgoptiPlus.AppImage
chmod 755 /tmp/ErgoptiPlus.AppImage
status=0
# A private TMPDIR: the runtime extracts under it, and the desktop launch below
# runs as another user, who could not write over root's extraction.
env USER=root LANG=C TMPDIR="$(mktemp -d)" /tmp/ErgoptiPlus.AppImage --appimage-extract-and-run --help \
	> "$LOG_DIR/help.out" 2> "$LOG_DIR/help.err" || status=$?
if [ "$expected" = refuse ]; then
	[ "$status" = "$REFUSAL_EXIT" ] || {
		cat "$LOG_DIR/help.err" >&2
		fail "--help exited $status, not the refusal status $REFUSAL_EXIT."
	}
	case "$libc" in
		musl) grep -q 'musl' "$LOG_DIR/help.err" || fail "The refusal does not name musl." ;;
		*) grep -q "glibc ${libc#glibc }" "$LOG_DIR/help.err" || fail "The refusal does not name $libc." ;;
	esac
	echo "[OK] Refused with status $status: $(sed -n 2p "$LOG_DIR/help.err")"
	exit 0
fi
[ "$status" = 0 ] || {
	tail -n 20 "$LOG_DIR/help.err" >&2
	fail "--help exited $status on $libc."
}
echo "[OK] --help exits 0 on $libc."

# ----------------------------------------------------------------------
# 3. A desktop launch, where apt can install an X server and GTK 3
# ----------------------------------------------------------------------
if ! command -v apt-get > /dev/null 2>&1; then
	echo "[OK] No apt-get in this image: the desktop launch is checked on apt images only."
	exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -q > "$LOG_DIR/apt.log" 2>&1 || fail "ENVIRONMENT: apt-get update failed."
apt-get install -y -q --no-install-recommends xvfb libgtk-3-0 x11-utils stalonetray xdotool \
	dbus procps >> "$LOG_DIR/apt.log" 2>&1 || {
	tail -n 5 "$LOG_DIR/apt.log" >&2
	fail "ENVIRONMENT: the desktop packages did not install."
}
useradd --create-home tester
cp /tmp/ErgoptiPlus.AppImage /home/tester/ErgoptiPlus.AppImage
chown tester: /home/tester/ErgoptiPlus.AppImage

# -displayfd picks a free display: containers sharing the host network also
# share the abstract X socket namespace.
Xvfb -displayfd 3 -screen 0 1280x800x24 3> "$LOG_DIR/display" > /dev/null 2>&1 &
for _ in $(seq 1 40); do [ -s "$LOG_DIR/display" ] && break; sleep 0.25; done
[ -s "$LOG_DIR/display" ] || fail "ENVIRONMENT: Xvfb never started."
DISPLAY=":$(cat "$LOG_DIR/display")"
export DISPLAY
stalonetray --geometry 1x1+0+0 --icon-size 48 --window-type dock > /dev/null 2>&1 &
tray_window=""
for _ in $(seq 1 40); do
	tray_window="$(xwininfo -name stalonetray 2> /dev/null | awk '/Window id:/ { print $4 }' || true)"
	[ -n "$tray_window" ] && break
	sleep 0.25
done
[ -n "$tray_window" ] || fail "ENVIRONMENT: stalonetray never started."

su tester -s /bin/sh -c "cd && export DISPLAY=$DISPLAY USER=tester XDG_RUNTIME_DIR=\$(mktemp -d) &&
	exec dbus-run-session -- ./ErgoptiPlus.AppImage --appimage-extract-and-run" > "$LOG_DIR/app.log" 2>&1 &
app=$!
stop() {
	kill "$app" 2> /dev/null || true
	pkill -KILL -u tester 2> /dev/null || true
	tail -n 25 "$LOG_DIR/app.log" >&2
	fail "$*"
}

status_window=""
for _ in $(seq 1 40); do
	sleep 1
	kill -0 "$app" 2> /dev/null || stop "The AppImage exited before its status window appeared."
	status_window="$(xwininfo -root -tree 2> /dev/null | awk '/"Ergopti\+": \(/ { print $1; exit }')"
	[ -n "$status_window" ] && break
done
[ -n "$status_window" ] || stop "No status window within 40 s."
xwininfo -id "$status_window" | grep -q 'Map State: IsViewable' || stop "The status window is not mapped."
echo "[OK] The status window is on screen."

icon=""
for _ in $(seq 1 20); do
	icon="$(xwininfo -tree -id "$tray_window" | grep -E '^ +0x' | grep -v ' 1x1+' | tail -n 1 || true)"
	[ -n "$icon" ] && break
	sleep 0.5
done
[ -n "$icon" ] || stop "No icon docked in stalonetray."
echo "[OK] The icon docks in an XEmbed tray."

# Quit is the last row of the tray menu: Up from no selection reaches it.
read -r x y w h << GEOMETRY
$(xwininfo -id "$(echo "$icon" | awk '{ print $1 }')" | awk '/Absolute upper-left X/ { x = $NF }
	/Absolute upper-left Y/ { y = $NF } /Width/ { w = $NF } /Height/ { h = $NF } END { print x, y, w, h }')
GEOMETRY
xdotool mousemove $((x + w / 2)) $((y + h / 2)) click 3
sleep 2
xdotool key Up
sleep 0.5
xdotool key Return
for _ in $(seq 1 30); do
	kill -0 "$app" 2> /dev/null || break
	sleep 0.5
done
kill -0 "$app" 2> /dev/null && stop "The AppImage still runs 15 s after Quit."
grep -q 'Degraded tray released by Quit' "$LOG_DIR/app.log" || stop "The AppImage exited without the Quit release."
if pgrep -u tester luajit > /dev/null; then stop "A luajit process outlived Quit."; fi
echo "[OK] Quit from the tray menu leaves no process behind."
