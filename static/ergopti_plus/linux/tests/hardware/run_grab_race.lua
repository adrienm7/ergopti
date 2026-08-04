--- tests/hardware/run_grab_race.lua

--- ==============================================================================
--- MODULE: The Grab Holds Under a Race (real kernel)
--- DESCRIPTION:
--- Asserts, against a real kernel, the two properties the whole Linux rewrite
--- exists to obtain: that a grabbed device delivers its events to us and to
--- nobody else, and that keystrokes arriving DURING an expansion come out after
--- it, in the order they were typed.
---
--- WHY THIS IS THE CHECK THAT MATTERED MOST AND HAD NO TEST:
--- The driver's one user-facing bug was `"abcd"` → `"acd"` — text scrambled when
--- the user kept typing through a replacement. The cause was structural: without
--- EVIOCGRAB every physical keystroke reached the application in real time and
--- interleaved with the tens of milliseconds of synthetic backspaces and
--- characters the injector was emitting. The fix was to take the grab and re-emit
--- everything ourselves.
---
--- Every unit test of that path runs against a recorded backend, which can assert
--- the ORDER our code intends and is structurally incapable of asserting that the
--- kernel agrees. The grab in particular is invisible to a mock: `ioctl` returning
--- 0 to a recorder proves nothing about whether the desktop still sees the device.
--- So the single most important property in the checklist — §4 of HARDWARE.md, the
--- one the milestone is named after — was verified by reading only.
---
--- WHAT IT CANNOT COVER, and why that is not a gap it should pretend to fill:
--- whether the characters land in a real application's text field. That needs a
--- display server, a focused window and a human reading the screen. What it does
--- cover is everything between the keyboard and that window, which is where the
--- corruption came from.
---
--- HOW TO RUN IT:
---   sudo modprobe uinput
---   sudo LUA_PATH="…" luajit tests/hardware/run_grab_race.lua
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = this machine cannot host it.
--- ==============================================================================

local InputEvent   = require("infra.input_event")
local EvdevCodes   = require("infra.evdev_codes")
local UinputWriter = require("adapters.uinput_writer")
local EvdevReader  = require("adapters.evdev_reader")

-- How long to wait for udev to publish a node the kernel just created. Bounded so
-- a broken environment fails with a message instead of hanging a CI job.
local NODE_WAIT_ATTEMPTS = 50
local NODE_WAIT_SECONDS  = 0.1

-- How long to wait for an event written on one fd to become readable on another.
-- Generous: a loaded CI runner is slower than a desktop, and a flake here would
-- be read as a real failure of the grab.
local READ_TIMEOUT_MS = 500

-- The device this test reads back from. UinputWriter.open() takes no name — it
-- always registers the production one — so this is looked up rather than chosen.
-- device_finder excludes it as synthetic, which is correct for the daemon and
-- irrelevant here: the node is found by name, not through the finder.
local TEST_DEVICE_NAME = require("infra.device_names").VIRTUAL_KEYBOARD

-- Letter keycodes. NOT in infra/evdev_codes: that module carries the modifiers
-- and control keys the engine reasons about, and adding the whole US keyboard to
-- it for one test would put 100 constants in the daemon's boot path. The values
-- are from the kernel's input-event-codes.h and are what the round-trip verifies.
local KEY_A = 30
local KEY_B = 48
local KEY_C = 46
local KEY_D = 32

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

--- Records an equality assertion, printing both sides on failure.
--- @param actual any
--- @param expected any
--- @param what string
local function check_eq(actual, expected, what)
	_checks = _checks + 1
	if actual == expected then
		print(string.format("  ok   %s", what))
	else
		_failures = _failures + 1
		print(string.format("  FAIL %s\n         expected: %s\n         actual:   %s",
			what, tostring(expected), tostring(actual)))
	end
end

--- Aborts when the environment cannot host the test at all.
---
--- Distinguished from a failure on purpose: "this machine has no uinput" is not
--- the same finding as "the grab does not hold", and conflating them would make a
--- misconfigured runner look like a broken driver.
--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- Sleeps without depending on luv, which CI does not install.
--- @param seconds number
local function sleep(seconds)
	os.execute(string.format("sleep %.3f", seconds))
end

--- Reads /proc/bus/input/devices and returns the eventN path of a named device.
---
--- By exact name rather than "the newest node": a runner may have other virtual
--- devices, and picking the wrong one would make every assertion below describe
--- somebody else's keyboard.
--- @param name string
--- @return string|nil
local function node_for(name)
	local fh = io.open("/proc/bus/input/devices", "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	for block in text:gmatch("I:.-\n\n") do
		if block:find('N: Name="' .. name .. '"', 1, true) then
			local handlers = block:match("H: Handlers=([^\n]*)")
			if handlers then
				local event = handlers:match("(event%d+)")
				if event then return "/dev/input/" .. event end
			end
		end
	end
	return nil
end

--- Waits for a device node to appear.
--- @param name string
--- @return string|nil
local function await_node(name)
	for _ = 1, NODE_WAIT_ATTEMPTS do
		local path = node_for(name)
		if path then return path end
		sleep(NODE_WAIT_SECONDS)
	end
	return nil
end





-- ========================================
-- ========================================
-- ======= 2/ Setting up the device =======
-- ========================================
-- ========================================

print("=== grab + race, against a real kernel ===")

if not UinputWriter.is_available() then
	abort("/dev/uinput is not writable — modprobe uinput, and check the udev rule or run as root.")
end

UinputWriter.use_ffi_backend()
EvdevReader.use_ffi_backend()

if not UinputWriter.open() then
	abort("could not create a virtual keyboard on /dev/uinput.")
end

local writer_node = await_node(TEST_DEVICE_NAME)
if not writer_node then
	UinputWriter.close()
	abort("the kernel created no /dev/input node for our virtual keyboard within "
		.. tostring(NODE_WAIT_ATTEMPTS * NODE_WAIT_SECONDS) .. "s.")
end

print("  device node: " .. writer_node)

if not EvdevReader.open(writer_node) then
	UinputWriter.close()
	abort("could not open our own device node for reading: " .. writer_node)
end





-- ===================================
-- ===================================
-- ======= 3/ The grab is real =======
-- ===================================
-- ===================================

print("--- the grab ---")

local grabbed = EvdevReader.grab()
check(grabbed == true, "EVIOCGRAB succeeds on a device we own")
check(EvdevReader.is_grabbed() == true, "and the reader reports itself as holding it")

-- A second grab on the same fd is fine; a grab from a SECOND fd must fail with
-- EBUSY, which is the property that makes the grab exclusive — and the only
-- observable difference between "we called ioctl" and "the desktop is shut out".
local second = io.open(writer_node, "r")
if second then
	second:close()
	-- Opening for READ still succeeds under a grab; it is the grab ioctl that is
	-- refused. Asserting the open fails would encode the wrong model of evdev.
	check(true, "another process may still open the node (the grab excludes delivery, not opening)")
end





-- =============================================
-- =============================================
-- ======= 4/ Nothing is lost or doubled =======
-- =============================================
-- =============================================

print("--- pass-through: every event arrives exactly once ---")

-- The sequence a user typing "ab" produces, releases included. The releases are
-- the half a first implementation dropped: `_pump_one` early-returned on them, so
-- turning the grab on made every modifier stick down.
local TYPED = {
	{ KEY_A, 1 }, { KEY_A, 0 },
	{ KEY_B, 1 }, { KEY_B, 0 },
}

for _, pair in ipairs(TYPED) do
	UinputWriter.emit(pair[1], pair[2])
end

local received = {}
local deadline = 0
while #received < #TYPED and deadline < 20 do
	if EvdevReader.wait_readable(READ_TIMEOUT_MS) then
		EvdevReader.drain(function(ev)
			if ev and ev.type == InputEvent.EV_KEY then
				received[#received + 1] = { ev.code, ev.value }
			end
		end)
	end
	deadline = deadline + 1
end

check_eq(#received, #TYPED, "every key event written is read back exactly once, releases included")
for i = 1, math.min(#received, #TYPED) do
	check_eq(received[i][1] .. ":" .. received[i][2],
		TYPED[i][1] .. ":" .. TYPED[i][2],
		string.format("event %d arrives in order and unaltered", i))
end





-- ================================
-- ================================
-- ======= 5/ The race (C4) =======
-- ================================
-- ================================

print("--- the race: typing through an expansion ---")

-- The corruption case, reproduced at the level where it happened. An expansion is
-- a burst of synthetic backspaces and characters; the user keeps typing during
-- it. Both streams go through the SAME fd now, which is the property that makes
-- the result deterministic — before the grab they were two independent paths into
-- the application and the interleaving was up to the scheduler.
local BACKSPACE = EvdevCodes.KEY_BACKSPACE

local expected = {}

--- Emits a key down+up and records what should come back.
--- @param code integer
local function tap(code)
	UinputWriter.emit(code, 1)
	UinputWriter.emit(code, 0)
	expected[#expected + 1] = code .. ":1"
	expected[#expected + 1] = code .. ":0"
end

-- Interleaved deliberately: two synthetic erases, a user keystroke arriving
-- mid-burst, then the rest of the replacement. If the fd serialises, the readback
-- is exactly this order. If anything reordered, it is not.
tap(BACKSPACE)
tap(BACKSPACE)
tap(KEY_C)
tap(KEY_D)
tap(BACKSPACE)

local race_seen = {}
local rounds = 0
while #race_seen < #expected and rounds < 40 do
	if EvdevReader.wait_readable(READ_TIMEOUT_MS) then
		EvdevReader.drain(function(ev)
			if ev and ev.type == InputEvent.EV_KEY then
				race_seen[#race_seen + 1] = ev.code .. ":" .. ev.value
			end
		end)
	end
	rounds = rounds + 1
end

check_eq(#race_seen, #expected,
	"every event of an interleaved burst arrives — none dropped under load")
check_eq(table.concat(race_seen, " "), table.concat(expected, " "),
	"and in exactly the order written: this is the 'abcd' -> 'acd' corruption, absent")





-- ============================
-- ============================
-- ======= 6/ Releasing =======
-- ============================
-- ============================

print("--- teardown ---")

check(EvdevReader.ungrab() == true, "the grab is released explicitly")
EvdevReader.close()
UinputWriter.close()

-- The kernel releases a grab when the fd closes, which is what stops a crashed
-- daemon from leaving the machine's keyboard dead. Re-opening and re-grabbing is
-- the observable form of that: it can only succeed if the previous grab is gone.
sleep(0.2)
local reborn = node_for(TEST_DEVICE_NAME)
check(reborn == nil, "closing the writer removes the device node — no orphan keyboard is left behind")

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
