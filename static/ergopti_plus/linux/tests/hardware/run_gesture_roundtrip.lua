--- tests/hardware/run_gesture_roundtrip.lua

--- ==============================================================================
--- MODULE: A Gesture Written to uinput Comes Back as a Gesture
--- DESCRIPTION:
--- Creates a multitouch touchpad, writes a real swipe and a real tap into it,
--- reads them back through the driver's OWN reader, and checks the decoder
--- classifies what the kernel delivered.
---
--- WHAT THIS CLOSES:
--- `test_mt_decoder.lua` feeds the decoder a table I wrote by hand from the
--- kernel's documentation. It proves the state machine is self-consistent with my
--- reading of the protocol, and nothing about what a kernel actually delivers —
--- the plan records that gap as "the event trace is a reconstruction, not a
--- capture". Here the events make a round trip through the kernel: written to
--- /dev/uinput, published on an input node, opened by the driver's evdev_reader,
--- decoded by the driver's mt_decoder.
---
--- What it still is not: a real Synaptics driver. The kernel passes uinput events
--- through rather than synthesising them, so the INTERLEAVING is mine — but the
--- struct layout, the ioctl numbers, the slot semantics and the non-blocking read
--- are all the kernel's, and those are what a hand-written table cannot check.
---
--- WHY IT ASSERTS THE WHOLE CHAIN AND NOT JUST THE DECODER:
--- Every piece has its own unit test and the feature still would not work if they
--- disagreed about a name or an offset. This is the only place the reader, the
--- decoder and the dispatcher meet.
---
--- Exit 0 = every assertion held. 1 = a failure. 2 = the environment cannot host
--- the test.
--- ==============================================================================

local Decoder = require("modules.gestures.mt_decoder")
local Finder = require("modules.gestures.touchpad_finder")
local Reader = require("adapters.evdev_reader")

local UINPUT_PATH = "/dev/uinput"
local DEVICE_NAME = "Ergopti Roundtrip Touchpad"
local SLOT_COUNT = 5

local SETTLE_ATTEMPTS = 50
local SETTLE_SECONDS  = 0.1

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

print("=== gesture round trip, through a real kernel ===")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then abort("no LuaJIT FFI on this interpreter.") end

local probe = io.open(UINPUT_PATH, "w")
if not probe then abort(UINPUT_PATH .. " is not writable.") end
probe:close()





-- =======================================
-- =======================================
-- ======= 1/ The virtual touchpad =======
-- =======================================
-- =======================================

ffi.cdef([[
	int open(const char *pathname, int flags);
	int close(int fd);
	int ioctl(int fd, unsigned long request, ...);
	long write(int fd, const void *buf, unsigned long count);

	struct rt_setup_t {
		unsigned short bustype; unsigned short vendor;
		unsigned short product; unsigned short version;
		char name[80];
		unsigned int ff_effects_max;
	};
	struct rt_abs_setup_t {
		unsigned short code;
		int value; int minimum; int maximum; int fuzz; int flat; int resolution;
	};
	struct rt_input_event {
		long tv_sec; long tv_usec;
		unsigned short type; unsigned short code; int value;
	};
]])

local UI_SET_EVBIT   = 0x40045564
local UI_SET_KEYBIT  = 0x40045565
local UI_SET_ABSBIT  = 0x40045567
local UI_SET_PROPBIT = 0x4004556e
local UI_ABS_SETUP   = 0x401c5504
local UI_DEV_SETUP   = 0x405c5503
local UI_DEV_CREATE  = 0x5501
local UI_DEV_DESTROY = 0x5502

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local SYN_REPORT = 0
local BTN_TOUCH = 0x14a
local INPUT_PROP_POINTER, INPUT_PROP_BUTTONPAD = 0x00, 0x02

local fd = ffi.C.open(UINPUT_PATH, 1 + 2048) -- O_WRONLY | O_NONBLOCK
if fd < 0 then abort("could not open " .. UINPUT_PATH) end

for _, bit in ipairs({ EV_KEY, EV_ABS, EV_SYN }) do
	ffi.C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", bit))
end
for _, prop in ipairs({ INPUT_PROP_POINTER, INPUT_PROP_BUTTONPAD }) do
	ffi.C.ioctl(fd, UI_SET_PROPBIT, ffi.cast("int", prop))
end
ffi.C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", BTN_TOUCH))
for _, entry in ipairs(Finder.FINGER_BITS) do
	ffi.C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", entry.bit))
end

local AXES = {
	{ code = Decoder.ABS_MT_SLOT,        min = 0, max = SLOT_COUNT - 1 },
	{ code = Decoder.ABS_MT_TRACKING_ID, min = -1, max = 65535 },
	{ code = Decoder.ABS_MT_POSITION_X,  min = 0, max = 4096 },
	{ code = Decoder.ABS_MT_POSITION_Y,  min = 0, max = 4096 },
}
for _, axis in ipairs(AXES) do
	ffi.C.ioctl(fd, UI_SET_ABSBIT, ffi.cast("int", axis.code))
	local abs = ffi.new("struct rt_abs_setup_t")
	abs.code = axis.code
	abs.minimum = axis.min
	abs.maximum = axis.max
	ffi.C.ioctl(fd, UI_ABS_SETUP, abs)
end

local setup = ffi.new("struct rt_setup_t")
setup.bustype = 0x18
setup.vendor  = 0x06cb
setup.product = 0xce2e
setup.version = 1
ffi.copy(setup.name, DEVICE_NAME, math.min(#DEVICE_NAME, 79))

if ffi.C.ioctl(fd, UI_DEV_SETUP, setup) < 0 then ffi.C.close(fd) ; abort("UI_DEV_SETUP refused.") end
if ffi.C.ioctl(fd, UI_DEV_CREATE) < 0 then ffi.C.close(fd) ; abort("UI_DEV_CREATE refused.") end

local function destroy()
	ffi.C.ioctl(fd, UI_DEV_DESTROY)
	ffi.C.close(fd)
end

--- Writes one event to the virtual device.
--- @param etype integer
--- @param code integer
--- @param value integer
local function emit(etype, code, value)
	local ev = ffi.new("struct rt_input_event")
	ev.tv_sec, ev.tv_usec = 0, 0
	ev.type, ev.code, ev.value = etype, code, value
	ffi.C.write(fd, ev, ffi.sizeof("struct rt_input_event"))
end




-- =======================================
-- =======================================
-- ======= 2/ Finding it back ============
-- =======================================
-- =======================================

--- Waits for the driver's own finder to see the device.
--- @return table|nil
local function wait_for_device()
	for _ = 1, SETTLE_ATTEMPTS do
		for _, described in ipairs(Finder.list()) do
			if described.name == DEVICE_NAME then return described end
		end
		os.execute("sleep " .. tostring(SETTLE_SECONDS))
	end
	return nil
end

local touchpad = wait_for_device()
if not touchpad then destroy() ; abort("the device never appeared to touchpad_finder.") end

check(true, "the driver's own finder located the device: " .. tostring(touchpad.path))
check(touchpad.max_fingers == SLOT_COUNT,
	string.format("and reads %d finger(s) from the kernel's bitmaps; got %s",
		SLOT_COUNT, tostring(touchpad.max_fingers)))

if not Reader.open(touchpad.path, Reader.TOUCHPAD) then
	destroy()
	abort("the driver's evdev_reader could not open " .. touchpad.path)
end
check(true, "the driver's evdev_reader opened it")




-- ==========================================
-- ==========================================
-- ======= 3/ Writing a real gesture ========
-- ==========================================
-- ==========================================

--- Plays one gesture into the device, then drains it through the real reader and
--- decodes it with the real decoder.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @return table|nil The gesture the decoder produced.
local function play(fingers, dx, dy)
	-- Drain whatever the previous gesture left behind FIRST.
	--
	-- The loop below stops as soon as the decoder yields a gesture, and the
	-- kernel may still hold the events after it — the trailing SYN, or a lift
	-- frame delivered late. Left in the buffer they arrive at the head of the
	-- next gesture and desynchronise its slot state, which is why the third
	-- gesture came back as nothing while the first two were correct.
	for _ = 1, 5 do
		if Reader.drain(function() end, Reader.TOUCHPAD) == 0 then break end
	end

	local decoder = Decoder.new()
	local base_x, base_y = 1000, 900
	local tool = {}
	for _, entry in ipairs(Finder.FINGER_BITS) do tool[entry.fingers] = entry.bit end

	-- Land, one finger at a time, the count walking up as the kernel does it.
	for index = 0, fingers - 1 do
		emit(EV_ABS, Decoder.ABS_MT_SLOT, index)
		emit(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 700 + index)
		emit(EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
		emit(EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y)
		if index > 0 then emit(EV_KEY, tool[index], 0) end
		emit(EV_KEY, tool[index + 1], 1)
		if index == 0 then emit(EV_KEY, BTN_TOUCH, 1) end
		emit(EV_SYN, SYN_REPORT, 0)
	end

	for step = 1, 4 do
		for index = 0, fingers - 1 do
			emit(EV_ABS, Decoder.ABS_MT_SLOT, index)
			emit(EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200 + math.floor(dx * step / 4))
			emit(EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(dy * step / 4))
		end
		emit(EV_SYN, SYN_REPORT, 0)
	end

	for index = fingers - 1, 0, -1 do
		emit(EV_ABS, Decoder.ABS_MT_SLOT, index)
		emit(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		emit(EV_KEY, tool[index + 1], 0)
		if index > 0 then emit(EV_KEY, tool[index], 1) end
		emit(EV_SYN, SYN_REPORT, 0)
	end
	emit(EV_KEY, BTN_TOUCH, 0)
	emit(EV_SYN, SYN_REPORT, 0)

	-- Drain through the driver's own reader. Several passes because the kernel
	-- delivers asynchronously and one drain is bounded.
	local out = nil
	for _ = 1, SETTLE_ATTEMPTS do
		local drained = Reader.drain(function(event)
			local gesture = decoder:feed(event)
			if gesture then out = gesture end
		end, Reader.TOUCHPAD)
		if out then break end
		if drained == 0 then os.execute("sleep " .. tostring(SETTLE_SECONDS)) end
	end
	return out
end

local swipe = play(3, 0, -600)
check(swipe ~= nil, "a three-finger upward swipe came back as a gesture")
if swipe then
	check(swipe.fingers == 3, string.format(
		"with THREE fingers — the count the kernel reported, not the number of "
			.. "contacts we could locate; got %s", tostring(swipe.fingers)))
	check(swipe.direction == "up", string.format(
		"and travelling UP — evdev Y grows downward, so a sign error here inverts "
			.. "every vertical gesture; got %s", tostring(swipe.direction)))
end

local tap = play(5, 0, 0)
check(tap ~= nil, "a five-finger tap came back as a gesture")
if tap then
	check(tap.fingers == 5, string.format(
		"with FIVE fingers — a count libinput cannot report at all; got %s",
		tostring(tap.fingers)))
	check(tap.tap == true, "and classified as a tap, which libinput also cannot do past three")
end

local left = play(4, -600, 0)
check(left ~= nil and left.direction == "left", string.format(
	"a four-finger swipe left came back as left; got %s",
	left and tostring(left.direction) or "nothing"))

Reader.close(Reader.TOUCHPAD)
destroy()

print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
