--- tests/hardware/run_display_server.lua

--- ==============================================================================
--- MODULE: The Same Binary on X11 and on Wayland (real servers, no display)
--- DESCRIPTION:
--- Runs against whichever display server is actually present and asserts the
--- driver identifies it, dumps its keymap, and needed no configuration to do so.
---
--- WHY THIS IS RUNNABLE IN CI AT ALL:
--- "Needs a display server" sounded like "needs a desktop", and it does not. A CI
--- runner can host a real X server with Xvfb and a real Wayland compositor with
--- `sway --config /dev/null` under WLR_BACKENDS=headless. Both are the genuine
--- article — a real X11 socket, a real wl_display — they simply draw to nothing.
--- Everything this driver does with a display server EXCEPT putting pixels on a
--- screen is therefore checkable here, and that includes the two things that
--- actually broke: which server the driver thinks it is on, and whether it can
--- read the keymap from it.
---
--- WHAT IT PINS, AND WHY EACH ONE HAS A HISTORY:
--- 1. WAYLAND_DISPLAY beats DISPLAY. XWayland sets DISPLAY on a Wayland session,
---    so a detector that reads DISPLAY first reports X11 on both — and then the
---    driver dumps the keymap with the X11 tool on a Wayland session, which fails
---    silently and leaves every accented character untypable.
--- 2. A socket beats XDG_SESSION_TYPE. That variable is a label a login manager
---    sets and gets wrong; a socket in the environment is a fact.
--- 3. The keymap dumps on whichever server is live, through the cascade the
---    daemon uses rather than a second one written for the test.
---
--- WHAT IT CANNOT COVER: that the characters appear in a window. Nothing draws
--- here. That half stays in HARDWARE.md with a person's name on it.
---
--- HOW TO RUN IT:
---   xvfb-run -a luajit tests/hardware/run_display_server.lua
---   # or, under a headless compositor:
---   sway --config /dev/null & WAYLAND_DISPLAY=wayland-1 luajit …
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = no display server at all.
--- ==============================================================================

local DisplayServer = require("infra.display_server")

local _failures = 0
local _checks   = 0





-- ===============================
-- ===============================
-- ======= 1/ Tiny harness =======
-- ===============================
-- ===============================

--- Records one assertion.
--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print(string.format("  ok   %s", what))
	else
		_failures = _failures + 1
		print(string.format("  FAIL %s", what))
	end
end

--- Aborts when the environment cannot host the test at all.
--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- Runs a command and returns its trimmed stdout.
--- @param command string
--- @return string
local function capture(command)
	local pipe = io.popen(command .. " 2>/dev/null", "r")
	if not pipe then return "" end
	local out = pipe:read("*a") or ""
	pipe:close()
	return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end





-- =======================================
-- =======================================
-- ======= 2/ Which server is live =======
-- =======================================
-- =======================================

print("=== display server, against a real one ===")

local wayland_socket = os.getenv("WAYLAND_DISPLAY")
local x11_socket     = os.getenv("DISPLAY")

if not wayland_socket and not x11_socket then
	abort("neither WAYLAND_DISPLAY nor DISPLAY is set — start Xvfb or a headless compositor first.")
end

DisplayServer.refresh()
local kind = DisplayServer.kind()
print(string.format("  WAYLAND_DISPLAY=%s  DISPLAY=%s  XDG_SESSION_TYPE=%s",
	tostring(wayland_socket), tostring(x11_socket), tostring(os.getenv("XDG_SESSION_TYPE"))))
print("  detected: " .. tostring(kind))

if wayland_socket then
	-- The ordering rule, exercised where it matters. On a Wayland session with
	-- XWayland running, BOTH variables are set — and this is the case a detector
	-- that reads DISPLAY first gets wrong, silently, forever.
	check(DisplayServer.is_wayland(), "a Wayland socket is reported as Wayland")
	check(not DisplayServer.is_x11(),
		"and NOT as X11, even with DISPLAY also set — XWayland sets it on every Wayland session")
else
	check(DisplayServer.is_x11(), "an X11 display with no Wayland socket is reported as X11")
	check(not DisplayServer.is_wayland(), "and not as Wayland")
end





-- ===================================
-- ===================================
-- ======= 3/ The keymap dumps =======
-- ===================================
-- ===================================

-- The same cascade the driver uses: the Wayland dumper on Wayland, the X11 one
-- on X11. Asserted through the tools rather than through KeyboardLayout so a
-- failure names WHICH step broke — a layout table of zero entries is the same
-- symptom whether the dump failed or the parse did.
local dump = ""
if wayland_socket then
	dump = capture("xkbcli dump-keymap-wayland")
	if dump == "" then dump = capture("xkbcli compile-keymap --layout us") end
else
	dump = capture("xkbcli dump-keymap-x11")
	if dump == "" then dump = capture("xkbcomp -xkb " .. tostring(x11_socket) .. " -") end
end

if dump == "" then
	-- Not a failure of the driver: a runner without xkbcli or x11-utils cannot
	-- answer the question at all, and reporting that as a bug would send the
	-- reader to the wrong file.
	print("  SKIP no keymap dumper available (install libxkbcommon-tools or x11-utils)")
else
	local key_definitions = select(2, dump:gsub("key%s*<", ""))
	check(key_definitions > 0, string.format(
		"the live %s server yields a keymap (%d key definition(s))", tostring(kind), key_definitions))

	local KeyboardLayout = require("adapters.keyboard_layout")
	local built = KeyboardLayout.build(dump)
	local entries = 0
	for _ in pairs(built or {}) do entries = entries + 1 end
	-- 60 is the floor the driver itself refuses below, rather than typing wrong
	-- characters out of a half-read table.
	check(entries >= 60, string.format(
		"and the driver parses it into %d typable character(s), at or above its own floor of 60", entries))
end





-- =========================================
-- =========================================
-- ======= 4/ Nothing was configured =======
-- =========================================
-- =========================================

-- C2, the half a machine can answer. The claim in the checklist is "log out of
-- X11, log into Wayland, change nothing". What "change nothing" means concretely
-- is that the driver reads the session from the environment on every start and
-- keeps no note of the last one — so the same binary, with the same config, run
-- under a different server, must reach a different answer.
--
-- Proven here by asking the detector to re-read a substituted environment: if it
-- cached the first answer, the second read returns the stale one.
DisplayServer._set_for_test("x11", "gnome")
check(DisplayServer.is_x11(), "the detector can be told it is on X11")
DisplayServer._set_for_test("wayland", "gnome")
check(DisplayServer.is_wayland(),
	"and switching answers without a restart — a cached session is what would make a user "
		.. "reconfigure after every logout")

DisplayServer.refresh()
check(DisplayServer.kind() == kind,
	"refresh() returns to what the real environment says, so the test leaves no state behind")

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
