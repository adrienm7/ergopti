#!/bin/sh
# tests/hardware/run_file_manager_folder.sh
#
# Headless proof of open_terminal_here and new_text_file_here on Linux: starts
# Xvfb, Openbox and a private D-Bus session, opens real Nautilus, Thunar and
# Dolphin windows, and checks what tests/hardware/run_file_manager_folder.lua
# reads and does in each state. Needs an ordinary user (Nautilus refuses root)
# and the packages xvfb openbox dbus-x11 xdotool x11-utils libglib2.0-bin
# nautilus thunar dolphin xterm luajit lua-luv.
# Usage: tests/hardware/run_file_manager_folder.sh (from any directory).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" != 0 ] || { echo "run as an ordinary user: Nautilus refuses root" >&2; exit 2; }
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }
}
need Xvfb; need openbox; need dbus-launch; need xdotool; need xprop; need gdbus
need nautilus; need thunar; need dolphin; need xterm; need luajit

WORK=$(mktemp -d)
export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY=":$((80 + $$ % 100))" XDG_SESSION_TYPE=x11 TERMINAL=xterm LANG=C.UTF-8
unset WAYLAND_DISPLAY
Xvfb "$DISPLAY" -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
# The processes of this fixture: every one inherits HOME="$WORK/home", the
# file managers' D-Bus-activated helpers included. Read from /proc, not pgrep.
own_pids() {
	for dir in /proc/[0-9]*; do
		[ "${dir#/proc/}" != $$ ] || continue
		grep -qz "^HOME=$WORK/home\$" "$dir/environ" 2>/dev/null && printf '%s\n' "${dir#/proc/}"
	done
}
# The newest fixture process whose command name is $1.
own_named() {
	found=""
	for pid in $(own_pids); do
		[ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$1" ] && found=$pid
	done
	printf '%s' "$found"
}
cleanup() {
	[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" >/dev/null 2>&1 || true
	for pid in $(own_pids); do kill "$pid" >/dev/null 2>&1 || true; done
	kill "$XVFB" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
sleep 1
eval "$(dbus-launch --sh-syntax)"
openbox >/dev/null 2>&1 &
sleep 1

A="$HOME/plain"; B="$HOME/l'été dir"; C="$HOME/third"
mkdir -p "$A" "$B" "$C"
FAILED=0
receipt() { (cd "$ROOT" && LUA_PATH="./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;" \
	luajit tests/hardware/run_file_manager_folder.lua "$@" 2>>"$WORK/receipt.err"); }
expect() {
	name=$1; want=$2; shift 2
	got=$(receipt "$@")
	if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: got [$got] want [$want]"; FAILED=1; fi
}
uri() { printf 'file://%s' "$1" | sed "s/ /%20/g; s/'/%27/g; s/é/%C3%A9/g"; }
active_bus() { xprop -notype -id "$(xdotool getactivewindow)" _GTK_UNIQUE_BUS_NAME | sed 's/.*= "\(.*\)"/\1/'; }
nautilus_action() {
	gdbus call --session --dest "$(active_bus)" --object-path /org/gnome/Nautilus/window/1 \
		--method org.gtk.Actions.Activate "$1" "$2" '{}' >/dev/null
	sleep 0.5
}
activate() {
	window=$(xdotool search --sync --onlyvisible --class "$1" | head -n 1)
	xdotool windowactivate --sync "$window"
	sleep 0.5
}

# Thunar first, so it owns org.freedesktop.FileManager1: the read must still
# ask the active Nautilus window's own process.
thunar --daemon >/dev/null 2>&1 &
sleep 2
nautilus "$A" >/dev/null 2>&1 &
sleep 4
expect "nautilus window reads its local folder" "folder	$A" read
owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
	--method org.freedesktop.DBus.GetNameOwner org.freedesktop.FileManager1)
[ "$owner" != "('$(active_bus)',)" ] && echo "ok   FileManager1 is owned by another process ($owner)" \
	|| { echo "FAIL the Nautilus window owns FileManager1: the unique-bus read is not exercised"; FAILED=1; }

nautilus_action open-location "[<'$(uri "$B")'>]"
expect "a navigation is read at once (quote, accent, space)" "folder	$B" read

expect "open_terminal_here starts the terminal" "terminal	started" terminal
sleep 2
term=$(own_named xterm)
if [ -n "$term" ] && [ "$(readlink "/proc/$term/cwd")" = "$B" ]; then echo "ok   the terminal runs in the folder"
else echo "FAIL the terminal is not in the folder (pid ${term:-none})"; FAILED=1; fi
[ -n "$term" ] && kill "$term"
activate org.gnome.Nautilus

base=$(cd "$ROOT" && LUA_PATH="./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;" \
	luajit -e 'require("core.lifecycle.engine.compat.utf8").install() io.write(require("core.i18n.engine.i18n").get("system_actions.new_text_file_name"))')
printf 'kept' > "$B/$base.txt"
expect "new_text_file_here skips the taken name" "created	$B/$base 2.txt	$base" new_file
[ "$(cat "$B/$base.txt")" = kept ] && [ -f "$B/$base 2.txt" ] && [ ! -s "$B/$base 2.txt" ] \
	&& echo "ok   the existing file is kept and the new one is empty" || { echo "FAIL file contents"; FAILED=1; }
sleep 1
windows=$(xdotool search --onlyvisible --class org.gnome.Nautilus | wc -l)
[ "$windows" = 1 ] && echo "ok   the reveal reused the window" || { echo "FAIL the reveal opened $windows windows"; FAILED=1; }
expect "the window still shows the folder after the reveal" "folder	$B" read

nautilus_action new-tab "[]"
expect "two tabs on one folder read as that folder" "folder	$B" read
nautilus_action open-location "[<'$(uri "$C")'>]"
expect "tabs on different folders are refused" "refused	ambiguous_tabs	" read
expect "no terminal from an ambiguous window" "terminal	refused" terminal
nautilus_action close-current-view "[]"
expect "closing the other tab admits the window again" "folder	$B" read

nautilus_action open-location "[<'trash:///'>]"
expect "trash:/// is not a local folder" "refused	not_local	" read
nautilus_action go-starred "[]"
expect "starred:/// is not a local folder" "refused	not_local	" read
expect "no file is created outside a local folder" "created	none" new_file

thunar "$C" >/dev/null 2>&1 &
sleep 3
activate Thunar
expect "Thunar is named, never guessed" "refused	unsupported_file_manager	Thunar" read
expect "no file is created from Thunar" "created	none" new_file
[ ! -e "$C/$base.txt" ] && echo "ok   nothing was created in the Thunar folder" || { echo "FAIL a file was created from Thunar"; FAILED=1; }

dolphin "$C" >/dev/null 2>&1 &
sleep 5
activate dolphin
expect "Dolphin is named, never guessed" "refused	unsupported_file_manager	Dolphin" read

xterm -e sleep 30 &
sleep 2
activate xterm
expect "a terminal is not a file manager" "refused	not_file_manager	" read

[ -s "$WORK/receipt.err" ] && { echo "receipt stderr:"; cat "$WORK/receipt.err"; }
[ "$FAILED" = 0 ] && echo "file manager folder receipts: all passed" || echo "file manager folder receipts: FAILED"
exit "$FAILED"
