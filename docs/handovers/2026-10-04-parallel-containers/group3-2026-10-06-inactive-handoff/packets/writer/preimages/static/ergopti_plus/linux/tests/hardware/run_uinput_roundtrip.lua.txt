--- tests/hardware/run_uinput_roundtrip.lua

--- ==============================================================================
--- MODULE: uinput ⇄ evdev Round Trip (real kernel)
--- DESCRIPTION:
--- Creates a real virtual keyboard on /dev/uinput, opens the /dev/input/eventN
--- node the kernel makes for it, takes EVIOCGRAB on that node, writes events
--- through the writer and reads them back through the reader.
---
--- WHY THIS EXISTS SEPARATELY FROM THE UNIT SUITE:
--- Every unit test of these two adapters runs against a recorded backend,
--- because the interpreter developers use has no FFI and no /dev/input. That is
--- the right shape for asserting ORDER and SEQUENCE, and it is structurally
--- incapable of asserting the one thing left: that the kernel accepts what we
--- send it. Four values decide that, none of them observable from a recorder —
--- the ioctl request numbers, the struct size, the field offsets, and the
--- capability bits registered before UI_DEV_CREATE. Get any of them wrong and
--- every mock still passes while a real machine gets nothing.
---
--- So this is not a duplicate of the unit tests at a higher cost. It is the only
--- assertion in the repository that the FFI code has ever been executed at all.
---
--- HOW TO RUN IT:
---   sudo modprobe uinput
---   sudo LUA_PATH="…" luajit tests/hardware/run_uinput_roundtrip.lua
--- Root is needed because /dev/uinput is root-owned until the udev rule from
--- install.sh --setup-perms is in place. CI runs it on ubuntu-latest, which is
--- the only place in this repo where a real kernel input path is exercised.
---
--- Exit code 0 = every assertion held. 1 = a failure, printed with what it was.
--- ==============================================================================

local InputEvent  = require("infra.input_event")
local DeviceNames = require("infra.device_names")
local UinputWriter = require("adapters.uinput_writer")
local EvdevReader  = require("adapters.evdev_reader")
local DeviceFinder = require("modules.hotstrings.device_finder")





-- =======================================
-- =======================================
-- ======= 1/ Tiny harness ===============
-- =======================================
-- =======================================

-- How long to wait for udev to publish the node the kernel just created. It is
-- normally there within a few milliseconds; the bound exists so a broken
-- environment fails with a message instead of hanging a CI job.
local NODE_WAIT_ATTEMPTS = 50
local NODE_WAIT_SECONDS  = 0.1

local _failures = 0
local _checks   = 0

--- Records one assertion.
--- @param condition boolean
--- @param what string What was being asserted, in the failure message.
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

--- Aborts with a message when the environment cannot host the test at all.
--- Distinguished from a failure on purpose: "this machine has no uinput" is not
--- the same finding as "our ioctl numbers are wrong".
--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

--- Sleeps without depending on luv, which is not installed in CI.
--- @param seconds number
local function sleep(seconds)
	os.execute(string.format("sleep %.3f", seconds))
end





-- =======================================
-- =======================================
-- ======= 2/ Finding our own node =======
-- =======================================
-- =======================================

--- Reads /proc/bus/input/devices and returns the eventN path of our device.
---
--- By exact name rather than "the newest node": a CI runner may have other
--- virtual devices, and picking the wrong one would make a passing round trip
--- prove nothing about the device we created.
--- @return string|nil path
local function find_our_node()
	local fh = io.open("/proc/bus/input/devices", "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()

	for _, dev in ipairs(DeviceFinder.parse_devices(text or "")) do
		if dev.name == DeviceNames.VIRTUAL_KEYBOARD then
			for _, handler in ipairs(dev.handlers) do
				local node = handler:match("^(event%d+)$")
				if node then return "/dev/input/" .. node end
			end
		end
	end
	return nil
end

--- Waits for the node to appear after UI_DEV_CREATE.
--- @return string|nil path
local function wait_for_node()
	for _ = 1, NODE_WAIT_ATTEMPTS do
		local path = find_our_node()
		if path then return path end
		sleep(NODE_WAIT_SECONDS)
	end
	return nil
end





-- =======================================
-- =======================================
-- ======= 3/ The round trip =============
-- =======================================
-- =======================================

print("")
print("uinput <-> evdev round trip (real kernel)")
print(string.rep("=", 60))

if not UinputWriter.use_ffi_backend() then
	abort("no LuaJIT FFI — this harness must run under luajit")
end
if not UinputWriter.is_available() then
	abort("/dev/uinput is not accessible — run `sudo modprobe uinput` and run this as root")
end

check_eq(UinputWriter.open(), true, "the kernel accepts UI_DEV_SETUP and UI_DEV_CREATE")
if not UinputWriter.is_open() then
	io.stderr:write("cannot continue: the virtual device was not created\n")
	os.exit(1)
end

local node = wait_for_node()
check(node ~= nil, "the created device appears in /proc/bus/input/devices under its declared name")
if not node then
	UinputWriter.close()
	os.exit(1)
end
print(string.format("       node: %s", node))

check_eq(EvdevReader.open(node), true, "the node opens non-blocking")
check_eq(EvdevReader.grab(), true, "EVIOCGRAB is accepted on a live device")

-- Nothing has been written yet, so a non-blocking read must come back empty
-- rather than blocking. This is the property the whole rewrite turned on, and it
-- is the one a recorder cannot prove: a recorder returns nil because it was
-- written to, not because the kernel had nothing.
check_eq(EvdevReader.read_event(), nil, "an idle device returns nothing instead of blocking")

-- A press, an autorepeat and a release: the three values, one of which the old
-- subprocess parser dropped entirely.
local SENT = {
	{ code = 30, value = 1 },
	{ code = 30, value = 2 },
	{ code = 30, value = 0 },
}
for _, ev in ipairs(SENT) do
	UinputWriter.emit(ev.code, ev.value)
end

-- The kernel delivers asynchronously; give it a moment before draining.
sleep(NODE_WAIT_SECONDS)

local received = {}
EvdevReader.drain(function(ev)
	-- The writer appends a SYN_REPORT after every key, and that is deliberate:
	-- without it the kernel buffers the event and the application sees nothing.
	-- Only the key reports are compared here.
	if ev.type == InputEvent.EV_KEY then
		received[#received + 1] = string.format("%d:%d", ev.code, ev.value)
	end
end)

check_eq(#received, #SENT,
	"every key report written comes back (SYN_REPORT frames excluded)")
check_eq(table.concat(received, " "), "30:1 30:2 30:0",
	"the codes and values survive the struct, in order and including the autorepeat")

check_eq(EvdevReader.ungrab(), true, "the grab is released on request")
EvdevReader.close()
check_eq(EvdevReader.is_open(), false, "the descriptor is closed")

UinputWriter.close()
check_eq(UinputWriter.is_open(), false, "UI_DEV_DESTROY is accepted and the device is gone")

sleep(NODE_WAIT_SECONDS)
check_eq(find_our_node(), nil,
	"the node disappears from /proc after the device is destroyed — a daemon that "
		.. "leaks it makes the next start enumerate two")

print("")
print(string.format("Total: %d check(s) - %d passed, %d failed",
	_checks, _checks - _failures, _failures))
print("")

os.exit(_failures > 0 and 1 or 0)
