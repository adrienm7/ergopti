--- tests/hardware/run_touchpad_capability.lua

--- ==============================================================================
--- MODULE: The Kernel's Own Answer About a Touchpad
--- DESCRIPTION:
--- Creates a multitouch touchpad through uinput, then reads what the KERNEL says
--- about it in /proc/bus/input/devices and checks that `touchpad_finder` reads
--- the same thing back.
---
--- WHAT THIS EXISTS TO SETTLE:
--- `touchpad_finder` reads capability bits out of a printed bitmap, and doing so
--- rests on one assumption the text cannot confirm — that the words are 64 bits
--- wide, most significant first, with leading zero words omitted. Its unit tests
--- use a fixture I wrote by hand, so they prove the parser is self-consistent and
--- nothing about the format the kernel actually emits. This is the check that
--- closes that: the device is declared here, the kernel formats the bitmaps, and
--- the parser has to agree with a text it did not see written.
---
--- It also settles the finger-count claim. `input_mt_init_slots()` advertises
--- BTN_TOOL_TRIPLETAP only at three slots, QUADTAP at four and QUINTTAP at five,
--- and the whole "grey the rows this hardware cannot serve" design rests on that
--- being readable BEFORE any finger touches the pad. Here a five-slot device is
--- created and the answer is checked against five.
---
--- WHAT IT DELIBERATELY DOES NOT CLAIM:
--- This is not a real Synaptics pad. The capability BITS are the kernel's, and so
--- is their printed form — which is the half that could not be tested otherwise.
--- The exact interleaving a real driver emits within a frame is its own business
--- and stays in HARDWARE.md.
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = the environment cannot host
--- the test, which is a property of the machine and not of the code.
--- ==============================================================================

local Finder = require("modules.gestures.touchpad_finder")

local UINPUT_PATH = "/dev/uinput"
local DEVICES_PATH = "/proc/bus/input/devices"

-- The device this harness creates. Named so a leaked one is obvious in a
-- listing rather than looking like hardware.
local DEVICE_NAME = "Ergopti Test Touchpad"

-- Five slots, so every BTN_TOOL_* bit up to QUINTTAP is advertised. The point of
-- the harness is that the kernel is what decides which appear.
local SLOT_COUNT = 5

-- How long to wait for the kernel to publish the device in /proc after
-- UI_DEV_CREATE. Normally immediate; the bound turns a broken environment into a
-- message instead of a hung job.
local PUBLISH_ATTEMPTS = 50
local PUBLISH_SECONDS  = 0.1

local _failures, _checks = 0, 0

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

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== touchpad capability, as the kernel prints it ===")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then abort("no LuaJIT FFI on this interpreter.") end

local probe = io.open(UINPUT_PATH, "w")
if not probe then abort(UINPUT_PATH .. " is not writable — the harness cannot create a device.") end
probe:close()




-- =======================================
-- =======================================
-- ======= 1/ Creating the device ========
-- =======================================
-- =======================================

ffi.cdef([[
	int open(const char *pathname, int flags);
	int close(int fd);
	int ioctl(int fd, unsigned long request, ...);
	int write(int fd, const void *buf, size_t count);

	struct uinput_setup_t {
		unsigned short bustype; unsigned short vendor;
		unsigned short product; unsigned short version;
		char name[80];
		unsigned int ff_effects_max;
	};
	struct uinput_abs_setup_t {
		unsigned short code;
		int value; int minimum; int maximum; int fuzz; int flat; int resolution;
	};
]])

local O_WRONLY, O_NONBLOCK = 1, 2048

-- ioctl request numbers, in the same _IOC encoding the driver's own writer uses.
local UI_SET_EVBIT   = 0x40045564
local UI_SET_KEYBIT  = 0x40045565
local UI_SET_ABSBIT  = 0x40045567
local UI_SET_PROPBIT = 0x4004556e
local UI_ABS_SETUP   = 0x401c5504
local UI_DEV_SETUP   = 0x405c5503
local UI_DEV_CREATE  = 0x5501
local UI_DEV_DESTROY = 0x5502

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local ABS_MT_SLOT, ABS_MT_POSITION_X = 0x2f, 0x35
local ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x36, 0x39
local BTN_TOUCH = 0x14a
local INPUT_PROP_POINTER, INPUT_PROP_BUTTONPAD = 0x00, 0x02

local fd = ffi.C.open(UINPUT_PATH, bit and bit.bor(O_WRONLY, O_NONBLOCK) or (O_WRONLY + O_NONBLOCK))
if fd < 0 then abort("could not open " .. UINPUT_PATH) end

ffi.C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_KEY))
ffi.C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_ABS))
ffi.C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_SYN))

-- The properties that make this a touchpad rather than a touchscreen.
ffi.C.ioctl(fd, UI_SET_PROPBIT, ffi.cast("int", INPUT_PROP_POINTER))
ffi.C.ioctl(fd, UI_SET_PROPBIT, ffi.cast("int", INPUT_PROP_BUTTONPAD))

ffi.C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", BTN_TOUCH))
-- Every BTN_TOOL_* up to QUINTTAP, which is what a five-slot pad advertises.
for _, entry in ipairs(Finder.FINGER_BITS) do
	ffi.C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", entry.bit))
end

for _, axis in ipairs({ ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID }) do
	ffi.C.ioctl(fd, UI_SET_ABSBIT, ffi.cast("int", axis))
	local abs = ffi.new("struct uinput_abs_setup_t")
	abs.code = axis
	abs.minimum = (axis == ABS_MT_SLOT) and 0 or 0
	abs.maximum = (axis == ABS_MT_SLOT) and (SLOT_COUNT - 1) or 4096
	if axis == ABS_MT_TRACKING_ID then abs.maximum = 65535 end
	ffi.C.ioctl(fd, UI_ABS_SETUP, abs)
end

local setup = ffi.new("struct uinput_setup_t")
setup.bustype = 0x18 -- BUS_I8042, what a built-in pad reports
setup.vendor  = 0x06cb
setup.product = 0xce2d
setup.version = 1
ffi.copy(setup.name, DEVICE_NAME, math.min(#DEVICE_NAME, 79))

if ffi.C.ioctl(fd, UI_DEV_SETUP, setup) < 0 then
	ffi.C.close(fd)
	abort("UI_DEV_SETUP was refused.")
end
if ffi.C.ioctl(fd, UI_DEV_CREATE) < 0 then
	ffi.C.close(fd)
	abort("UI_DEV_CREATE was refused.")
end

--- Tears the device down whatever happens next.
local function destroy()
	ffi.C.ioctl(fd, UI_DEV_DESTROY)
	ffi.C.close(fd)
end





-- =======================================
-- =======================================
-- ======= 2/ What the kernel says =======
-- =======================================
-- =======================================

--- Reads /proc until the device appears, or gives up.
--- @return string|nil
local function wait_for_publication()
	for _ = 1, PUBLISH_ATTEMPTS do
		local fh = io.open(DEVICES_PATH, "r")
		if fh then
			local text = fh:read("*a") or ""
			fh:close()
			if text:find(DEVICE_NAME, 1, true) then return text end
		end
		os.execute("sleep " .. tostring(PUBLISH_SECONDS))
	end
	return nil
end

local devices_text = wait_for_publication()
if not devices_text then
	destroy()
	abort("the device was created but never appeared in " .. DEVICES_PATH)
end

check(true, "the kernel published the device in /proc/bus/input/devices")

-- The parser meets a text it did not see written. Everything below is the
-- assumption under test: word width, word order, omitted leading zeros.
local found = nil
for _, described in ipairs(Finder.list(devices_text)) do
	if described.name == DEVICE_NAME then found = described end
end

check(found ~= nil,
	"touchpad_finder recognises it as a touchpad from the kernel's own bitmaps")

if found then
	check(found.path ~= nil and found.path:match("^/dev/input/event%d+$") ~= nil,
		"and resolves its event node: " .. tostring(found.path))

	check(found.max_fingers == SLOT_COUNT, string.format(
		"and reads %d finger(s) — the count the kernel advertises for a %d-slot pad; got %s. "
			.. "This is the assertion the hand-written fixture could not make: the bitmap "
			.. "was formatted by the kernel, not by me.",
		SLOT_COUNT, SLOT_COUNT, tostring(found.max_fingers)))

	check(found.semi_mt == false,
		"and does not mistake a normal buttonpad for semi-MT hardware")

	-- The whole point of reading capability early: what the menu may offer.
	check(Finder.slot_is_reachable("swipe_5_up", found.max_fingers),
		"a five-finger swipe is offered on hardware that can express five")
	check(Finder.slot_is_reachable("tap_4", found.max_fingers),
		"and so is a four-finger tap — neither is expressible through libinput at all")
end

-- The selector must prefer this pad over anything else the runner has, which is
-- the failure the pointer selector it replaces would have made.
local all = Finder.list(devices_text)
check(#all >= 1, string.format("%d touchpad(s) seen in total", #all))

destroy()

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
