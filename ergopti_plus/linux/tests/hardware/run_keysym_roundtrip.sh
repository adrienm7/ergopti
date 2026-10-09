#!/usr/bin/env bash
# tests/hardware/run_keysym_roundtrip.sh
#
# ==============================================================================
# MODULE: Our Keycodes Come Back as the Characters We Meant
# DESCRIPTION:
# Emits keystrokes on a real uinput device and asks a real X server what
# characters they produced.
#
# WHY THIS IS THE ONE ROUND TRIP THAT WAS NEVER CLOSED:
# The driver resolves a character to a (keycode, modifiers) pair by parsing the
# XKB keymap itself. Everything downstream of that is verified — the ioctls, the
# struct, the grab, the ordering — and the parse is verified against fixtures and
# against real system keymaps. What none of that can tell us is whether the pair
# we chose actually produces the character we wanted when a real X server maps it
# back. Our parse and the server's could agree with each other and both differ
# from what we intended; a level index off by one, a shift that should have been
# AltGr, and every accented expansion types the wrong glyph while every test
# stays green.
#
# So this closes the loop from the other end: pick characters out of the driver's
# own table, press exactly what it says, and let `xev` — an ordinary X client
# reading the same keymap every application reads — report what arrived.
#
# WHAT IT STILL CANNOT SEE: whether a human would call the result correct in
# their editor's font. It reports keysyms, not pixels. That is the residue.
#
# IT DOES NOT RUN IN CI, AND THE REASON IS ARCHITECTURAL RATHER THAN A BUG.
# Tried on 2026-08-05 under xvfb-run: every character failed, with the driver
# resolving and emitting correctly each time. Xvfb is a virtual X server with a
# DUMMY keyboard — it does not enumerate /dev/input and has no evdev backend at
# all, so a keystroke on a uinput device has no path to reach it. No amount of
# focus or root-window listening changes that; the events never arrive.
#
# It needs a real Xorg with the evdev or libinput driver, which means a machine
# with a graphics stack. So this runs from HARDWARE.md on the target machine, and
# it is the only item there that a person does not have to JUDGE — they start it
# and read the exit code.
#
# Exit 0 = every character came back as itself. 1 = a mismatch. 2 = the
# environment cannot host the test.
# ==============================================================================

set -uo pipefail

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUA_BIN="$(command -v luajit || command -v lua5.4 || command -v lua || true)"
export LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"

PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "  ok   $1"; }
no()   { FAIL=$((FAIL + 1)); say "  FAIL $1"; }
skip() { say "  SKIP $1"; }

say "=== keysym round trip, real uinput into a real X server ==="

[ -n "$LUA_BIN" ]                  || { echo "ENVIRONMENT: no Lua interpreter" >&2; exit 2; }
[ -n "${DISPLAY:-}" ]              || { echo "ENVIRONMENT: no DISPLAY — run under xvfb-run" >&2; exit 2; }
command -v xev >/dev/null 2>&1     || { echo "ENVIRONMENT: xev is not installed (x11-utils)" >&2; exit 2; }
[ -w /dev/uinput ]                 || { echo "ENVIRONMENT: /dev/uinput is not writable" >&2; exit 2; }

# The characters to prove. Deliberately a mix: an unshifted letter, a shifted
# one, and a digit — every level the driver's table distinguishes. Accented
# characters are NOT hardcoded here: which ones exist depends on the layout the
# server was started with, and the Lua half below picks them from the driver's
# own table so the set adapts instead of failing on a keymap that lacks them.
PROBE_CHARS='a Z 5'

# ── The X client that reports what arrived ──────────────────────────────────
# On the ROOT window. Under a bare Xvfb there is no window manager to give an
# ordinary xev window the input focus, so its own window receives nothing and
# every character reads as a mismatch. The root window is where key events land
# when focus is PointerRoot, which is the default with no WM running.
xev -root -event keyboard > /tmp/xev-out.txt 2>/dev/null &
XEV_PID=$!
sleep 1

if ! kill -0 "$XEV_PID" 2>/dev/null; then
    echo "ENVIRONMENT: xev did not start under this display" >&2
    exit 2
fi

# ── Emit through the driver's own writer, at the driver's own answer ─────────
# The Lua half resolves each character through adapters/keyboard_layout — the
# same call the injector makes — and presses exactly what it returns. Doing it
# any other way would test a second implementation.
cd "$DRIVER_DIR" || exit 2
"$LUA_BIN" - "$PROBE_CHARS" <<'LUA_EOF'
local UinputWriter   = require("adapters.uinput_writer")
local KeyboardLayout = require("adapters.keyboard_layout")
local EvdevCodes     = require("infra.evdev_codes")

local MODIFIER_CODES = { shift = EvdevCodes.KEY_LEFTSHIFT, altgr = EvdevCodes.KEY_RIGHTALT }

-- The live keymap, through the driver's own cascade.
if not KeyboardLayout.refresh() then
    io.stderr:write("could not resolve the layout\n")
    os.exit(2)
end
if not UinputWriter.open() then
    io.stderr:write("could not open /dev/uinput\n")
    os.exit(2)
end

-- Give the kernel and the X server a moment to notice the new device; a
-- keystroke emitted before the server has it goes nowhere and reads as a
-- mismatch rather than as a race.
os.execute("sleep 1.5")

local wanted = {}
for char in (arg[1] or ""):gmatch("%S+") do wanted[#wanted + 1] = char end

-- Plus whatever accented characters this layout actually has, chosen from the
-- driver's own table so the probe adapts to the keymap instead of assuming one.
local ACCENT_CANDIDATES = { "é", "è", "à", "ç", "ñ", "ä", "ö" }
for _, char in ipairs(ACCENT_CANDIDATES) do
    if KeyboardLayout.resolve(char) then wanted[#wanted + 1] = char end
    if #wanted >= 6 then break end
end

local out = io.open("/tmp/probe-chars.txt", "w")
for _, char in ipairs(wanted) do
    local step = KeyboardLayout.resolve(char)
    if step then
        out:write(char, "\n")
        for _, mod in ipairs(step.mods) do UinputWriter.emit(MODIFIER_CODES[mod], 1) end
        UinputWriter.emit(step.keycode, 1)
        UinputWriter.emit(step.keycode, 0)
        for i = #step.mods, 1, -1 do UinputWriter.emit(MODIFIER_CODES[step.mods[i]], 0) end
        os.execute("sleep 0.15")
    end
end
out:close()
UinputWriter.close()
LUA_EOF

LUA_STATUS=$?
sleep 1
kill "$XEV_PID" 2>/dev/null

if [ "$LUA_STATUS" = "2" ]; then
    echo "ENVIRONMENT: the driver could not open the layout or the device" >&2
    exit 2
fi

# ── Compare what we meant with what arrived ─────────────────────────────────
if [ ! -s /tmp/probe-chars.txt ]; then
    no "the driver resolved none of the probe characters — nothing was emitted"
    exit 1
fi

while read -r CHAR; do
    # xev prints the character it decoded in the (keysym, "…") tail of each
    # KeyPress line. Matching on that rather than on the keysym NAME keeps this
    # working for every character without a name table of our own.
    if grep -q "KeyPress" /tmp/xev-out.txt && grep -qF "\"${CHAR}\"" /tmp/xev-out.txt; then
        ok "the X server decoded our keystroke for '${CHAR}' back to '${CHAR}'"
    else
        no "'${CHAR}' was pressed as the driver's table says, and the X server reported something else"
    fi
done < /tmp/probe-chars.txt

say "  passed: ${PASS}   failed: ${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -gt 0 ] || { echo "ENVIRONMENT: nothing was compared" >&2; exit 2; }
exit 0
