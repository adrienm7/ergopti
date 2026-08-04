#!/usr/bin/env bash
# tests/hardware/validate.sh
#
# ==============================================================================
# MODULE: Hardware Validation Runner
# DESCRIPTION:
# Walks the checklist in HARDWARE.md on a real machine and writes a report.
#
# WHY THIS EXISTS:
# Seven checks in the plan cannot run in CI: they need a real kernel, a real
# display server, a real panel and a real keyboard layout. Left as prose they get
# done once, by whoever wrote them, and never again — and a checklist nobody
# re-runs is a checklist that silently stops being true.
#
# Everything a machine can answer, this answers. What is left is genuinely human
# — does the text appear, is the tooltip the right shade — and those are prompted
# one at a time and recorded with the rest, so a run produces one artefact
# covering the whole list rather than a memory of having looked.
#
# USAGE:
#   bash validate.sh              # full run, prompts for the human checks
#   bash validate.sh --auto-only  # machine checks only, no prompts (for a log)
#
# EXIT: 0 every automatic check passed, 1 one failed, 2 the environment cannot
# run them at all. A human check answered "no" fails the run.
# ==============================================================================

set -uo pipefail

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT="${ERGOPTI_HW_REPORT:-/tmp/ergopti-hardware-$(date +%Y%m%d-%H%M%S).log}"
AUTO_ONLY=0
[ "${1:-}" = "--auto-only" ] && AUTO_ONLY=1

PASS=0
FAIL=0
SKIP=0

# Colours only when a terminal is attached: a report piped to a file should not
# be full of escape sequences.
if [ -t 1 ]; then
	C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
	C_OK=''; C_NO=''; C_WARN=''; C_OFF=''
fi

say() { printf '%s\n' "$*" | tee -a "$REPORT" >/dev/null; printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "  ${C_OK}PASS${C_OFF}  $1"; }
no()   { FAIL=$((FAIL + 1)); say "  ${C_NO}FAIL${C_OFF}  $1"; }
skip() { SKIP=$((SKIP + 1)); say "  ${C_WARN}SKIP${C_OFF}  $1"; }

section() { say ""; say "=== $1 ==="; }

# A question only a person can answer. Recorded with the automatic results so the
# report covers the whole checklist rather than the machine-readable half.
ask() {
	local question="$1"
	if [ "$AUTO_ONLY" = "1" ]; then
		skip "$question (--auto-only)"
		return
	fi
	local answer=""
	printf '  %s [y/n/s] ' "$question"
	read -r answer </dev/tty || answer="s"
	case "$answer" in
		y|Y) ok "$question" ;;
		n|N) no "$question" ;;
		*)   skip "$question (skipped by operator)" ;;
	esac
}

say "Ergopti hardware validation — $(date -Is)"
say "driver: $DRIVER_DIR"
say "report: $REPORT"




# ==============================================================================
# ======= 1/ Permissions and devices ===========================================
# ==============================================================================

section "0. Permissions (HARDWARE.md §0)"

if [ -e /dev/uinput ]; then
	ok "/dev/uinput exists"
	if [ -w /dev/uinput ]; then
		ok "/dev/uinput is writable by this user"
	else
		# The most common cause by far, and the one whose fix is not obvious:
		# group membership is read at session start, so adding the group is not
		# enough — the user has to log out.
		no "/dev/uinput is NOT writable — run install.sh --setup-perms, then LOG OUT and back in"
	fi
else
	no "/dev/uinput is missing — 'sudo modprobe uinput', and check modules-load.d"
fi

for group in input uinput; do
	if id -nG | tr ' ' '\n' | grep -qx "$group"; then
		ok "member of group '$group'"
	else
		no "NOT a member of group '$group' — group membership is read at login, so log out after adding it"
	fi
done

if [ -r /proc/bus/input/devices ]; then
	ok "/proc/bus/input/devices is readable"
else
	no "/proc/bus/input/devices unreadable — device selection cannot work"
fi




# ==============================================================================
# ======= 2/ Display server ====================================================
# ==============================================================================

section "1./11. Display server (HARDWARE.md §1, §11)"

# The daemon's own ordering: WAYLAND_DISPLAY beats DISPLAY, because XWayland sets
# DISPLAY on a Wayland session and reading that first reports X11 on both.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
	ok "session is Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
	SERVER=wayland
elif [ -n "${DISPLAY:-}" ]; then
	ok "session is X11 (DISPLAY=$DISPLAY)"
	SERVER=x11
else
	no "neither WAYLAND_DISPLAY nor DISPLAY is set — run this from inside a graphical session"
	SERVER=none
fi

say "  note: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}, XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}"
say "  the checklist is only complete once this has been run under BOTH servers (C2)"




# ==============================================================================
# ======= 3/ Keyboard layout ===================================================
# ==============================================================================

section "3. Layout resolution (HARDWARE.md §3)"

# Same cascade the driver uses, in the same order, so a failure here is the
# failure the daemon would hit.
LAYOUT_DUMP=""
if command -v xkbcli >/dev/null 2>&1; then
	if [ "$SERVER" = "wayland" ]; then
		LAYOUT_DUMP="$(xkbcli dump-keymap-wayland 2>/dev/null)"
	else
		LAYOUT_DUMP="$(xkbcli dump-keymap-x11 2>/dev/null)"
	fi
fi
if [ -z "$LAYOUT_DUMP" ] && command -v xkbcomp >/dev/null 2>&1 && [ "$SERVER" = "x11" ]; then
	LAYOUT_DUMP="$(xkbcomp -xkb "${DISPLAY}" - 2>/dev/null)"
fi

if [ -n "$LAYOUT_DUMP" ]; then
	KEY_COUNT="$(printf '%s' "$LAYOUT_DUMP" | grep -c 'key *<' || true)"
	# The driver refuses a table under 60 entries as a parse failure rather than
	# typing wrong characters from a half-read keymap.
	if [ "${KEY_COUNT:-0}" -ge 60 ]; then
		ok "keymap dumped and parsed ($KEY_COUNT key definitions)"
	else
		no "keymap dumped but only $KEY_COUNT key definitions — the driver refuses anything under 60"
	fi
else
	no "no keymap could be dumped — install xkbcommon-tools (xkbcli) or x11-utils (xkbcomp)"
fi

if command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1; then
	ok "a clipboard tool is available (needed for characters no key can produce)"
else
	# Not fatal, but it is the difference between a Spanish pack working on a
	# French layout and a replacement being lost after the trigger was erased.
	no "no clipboard tool — a replacement the layout cannot type will be REPORTED AND LOST"
fi




# ==============================================================================
# ======= 4/ Service and tray ==================================================
# ==============================================================================

section "9. Tray and service (HARDWARE.md §9)"

if command -v systemctl >/dev/null 2>&1; then
	UNITS="$(systemctl --user list-unit-files 'ergopti*' --no-legend 2>/dev/null | wc -l)"
	if [ "${UNITS:-0}" -eq 1 ]; then
		ok "exactly one ergopti user unit is installed"
	elif [ "${UNITS:-0}" -eq 0 ]; then
		skip "no ergopti user unit installed (fine if you start it by hand or via XDG autostart)"
	else
		# Two units means two daemons, each trying to grab the keyboard.
		no "$UNITS ergopti units installed — two enabled units means two daemons grabbing the keyboard"
	fi
else
	skip "no systemctl (Alpine and friends) — check ~/.config/autostart/ instead"
fi

# The tray needs a StatusNotifierItem host. GNOME needs an extension for it, which
# is a property of GNOME rather than a fault here, so it is reported not failed.
if [ "$SERVER" != "none" ]; then
	if command -v gdbus >/dev/null 2>&1 &&
		gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus \
			-m org.freedesktop.DBus.ListNames 2>/dev/null | grep -q StatusNotifierWatcher; then
		ok "a StatusNotifierWatcher is running — the tray icon has a host"
	else
		skip "no StatusNotifierWatcher — on GNOME install the AppIndicator extension; on dwm/i3 run snixembed"
	fi
fi




# ==============================================================================
# ======= 5/ The parts only a person can see ===================================
# ==============================================================================

section "Automated kernel + keymap checks"

# These two used to be human checks. They are not any more, and the difference
# matters: a question a person answers once is a question that stops being
# answered, while a script that fails is a script somebody fixes.
LUA_BIN="$(command -v luajit || command -v lua5.4 || command -v lua || true)"
HW_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"

if [ -z "$LUA_BIN" ]; then
	skip "no Lua interpreter — cannot run the kernel and keymap harnesses"
else
	if ( cd "$DRIVER_DIR" && sudo env LUA_PATH="$HW_PATH" "$LUA_BIN" \
		tests/hardware/run_grab_race.lua >>"$REPORT" 2>&1 ); then
		ok "grab holds and an interleaved burst comes back in order (C4, HARDWARE.md §4)"
	else
		case $? in
			2) skip "grab race: this machine cannot host it (no writable /dev/uinput)" ;;
			*) no  "grab race FAILED — see $REPORT; this is the 'abcd' -> 'acd' corruption" ;;
		esac
	fi

	if ( cd "$DRIVER_DIR" && env LUA_PATH="$HW_PATH" "$LUA_BIN" \
		tests/hardware/run_layout_resolution.lua >>"$REPORT" 2>&1 ); then
		ok "real fr/es/us/de keymaps resolve, and each refuses the others' letters whole"
	else
		case $? in
			2) skip "layout resolution: xkbcli is not installed" ;;
			*) no  "layout resolution FAILED — see $REPORT" ;;
		esac
	fi
fi


section "Human checks (HARDWARE.md §1-§10)"

say "  Start the daemon in another terminal first:"
say "    ergopti-hotstrings --verbose 2>&1 | tee /tmp/ergopti.log"
say ""

ask "Typing appears normally on screen with the daemon running and grabbing?"
ask "Typing 'NT' + apostrophe expands to N'T immediately, with the right apostrophe?"
ask "A French sentence (e a c u, guillemets) comes out correct on YOUR layout?"
# The event-ordering half of C4 is asserted by run_grab_race.lua above. What is
# left for a person is whether the characters land in a real application's text
# field, which needs a focused window and eyes on the screen.
ask "Typing fast THROUGH an expansion leaves the text in order IN A REAL EDITOR, ten times? (C4)"
ask "Holding a letter until it repeats, then a trigger, erases the right count?"
ask "Ctrl+S / Ctrl+A / Alt+Tab cause no expansion, and a trigger still fires after?"
ask "Backspace immediately after an expansion restores the trigger exactly?"
ask "Clicking elsewhere mid-trigger prevents the expansion?"
ask "The tray icon appears and its Hotstrings submenu lists categories with counts?"
ask "Toggling a category greys its sections, and the choice survives a restart?"
ask "The preview tooltip appears, does not take focus, and clicks pass through it?"
ask "The magic key can be changed from the menu, and the new key works?"




# ==============================================================================
# ======= 6/ Report ============================================================
# ==============================================================================

section "Result"
say "  passed: $PASS   failed: $FAIL   skipped: $SKIP"
say "  full report: $REPORT"

if [ "$FAIL" -gt 0 ]; then
	say "  ${C_NO}Validation FAILED — see the failures above.${C_OFF}"
	exit 1
fi
if [ "$PASS" -eq 0 ]; then
	say "  ${C_WARN}Nothing could be checked at all — is this a graphical Linux session?${C_OFF}"
	exit 2
fi
say "  ${C_OK}Every check that ran passed.${C_OFF}"
[ "$SKIP" -gt 0 ] && say "  ${C_WARN}$SKIP check(s) skipped — the list is only complete when they are answered too.${C_OFF}"
exit 0
