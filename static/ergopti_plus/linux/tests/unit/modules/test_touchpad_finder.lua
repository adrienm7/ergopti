--- tests/unit/modules/test_touchpad_finder.lua

--- ==============================================================================
--- MODULE: Touchpad Selection and Capability
--- DESCRIPTION:
--- Picking the touchpad out of /proc/bus/input/devices, and reading how many
--- fingers it can count before any finger touches it.
---
--- WHY THE CAPABILITY IS READ FROM /proc RATHER THAN FROM AN ioctl:
--- The kernel publishes the same bits both ways, but an ioctl means computing a
--- request number by hand, and a mistake there does not fail loudly — the call
--- returns arbitrary bits and the menu greys the wrong rows. Text can be pinned
--- by a fixture, which is what this file does.
---
--- WHY THE HARDWARE ANSWER MATTERS:
--- `input_mt_init_slots()` advertises BTN_TOOL_TRIPLETAP only at 3 slots, QUADTAP
--- at 4 and QUINTTAP at 5. Microsoft's Precision Touchpad spec requires only
--- three simultaneous contacts, so a fully conformant pad may stop there — and on
--- that machine twenty of the declared gesture slots can never fire, whatever the
--- software does.
---
--- THE ASSUMPTION UNDER TEST:
--- The bitmaps are printed as 64-bit words, most significant first, with leading
--- zero words omitted. That is right on every machine this driver targets and
--- wrong on a 32-bit kernel, and there is no way to tell from the text. What
--- makes it acceptable is the DIRECTION of the failure, which the last case here
--- pins: an unreadable capability offers every gesture rather than none.
--- ==============================================================================

local helpers = require("tests.helpers")

local Finder = helpers.load_module("modules.gestures.touchpad_finder")

-- A real /proc/bus/input/devices excerpt: a keyboard, a five-finger touchpad and
-- a plain USB mouse. The mouse is here because the pointer selector this module
-- replaces would have returned it — it comes first and its name matches.
local DEVICES = [[
I: Bus=0003 Vendor=046d Product=c52b Version=0111
N: Name="Logitech USB Receiver Mouse"
P: Phys=usb-0000:00:14.0-1/input0
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/0003:046D:C52B.0001/input/input3
H: Handlers=mouse0 event3
B: PROP=0
B: EV=17
B: KEY=1f0000 0 0 0 0
B: ABS=0
B: REL=1943

I: Bus=0011 Vendor=0001 Product=0001 Version=ab54
N: Name="AT Translated Set 2 keyboard"
P: Phys=isa0060/serio0
S: Sysfs=/devices/platform/i8042/serio0/input/input0
H: Handlers=sysrq kbd event0 leds
B: PROP=0
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe
B: ABS=0

I: Bus=0018 Vendor=06cb Product=ce2d Version=0100
N: Name="SynPS/2 Synaptics TouchPad"
P: Phys=isa0060/serio1/input0
S: Sysfs=/devices/platform/i8042/serio1/input/input7
H: Handlers=mouse1 event7
B: PROP=5
B: EV=b
B: KEY=e520 10000 0 0 0 0
B: ABS=661800011000003
]]

--- The touchpad record from the fixture.
--- @return table
local function touchpad()
	local found, reason = Finder.find(DEVICES)
	helpers.assert_true(found ~= nil, "a touchpad must be found: " .. tostring(reason))
	return found
end




-- =================================================================
-- =================================================================
-- ======= 1/ Reading a printed bitmap =============================
-- =================================================================
-- =================================================================

helpers.describe("touchpad finder: the bitmap reader", function()

	helpers.it("finds a bit in the last printed word", function()
		-- Bit 0 and bit 3 of 0x9.
		helpers.assert_true(Finder.bit_set("9", 0))
		helpers.assert_true(Finder.bit_set("9", 3))
		helpers.assert_true(not Finder.bit_set("9", 1))
	end)

	helpers.it("counts words from the RIGHT, not the left", function()
		-- Words are printed most significant first, so "1 0" means bit 64, not
		-- bit 0. Reading them left to right is the single easiest mistake here and
		-- it silently shifts every capability by a whole word.
		helpers.assert_true(Finder.bit_set("1 0", 64), "bit 64 lives in the higher word")
		helpers.assert_true(not Finder.bit_set("1 0", 0), "and bit 0 is not set")
	end)

	helpers.it("answers false rather than raising for a bit past the end", function()
		helpers.assert_true(not Finder.bit_set("f", 4096))
		helpers.assert_true(not Finder.bit_set("", 0))
		helpers.assert_true(not Finder.bit_set(nil, 0))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Choosing the device ==================================
-- =================================================================
-- =================================================================

helpers.describe("touchpad finder: which device", function()

	helpers.it("finds the touchpad and not the mouse", function()
		local found = touchpad()
		helpers.assert_eq(found.path, "/dev/input/event7",
			"the pointer selector this replaces returns the FIRST device whose name "
				.. "matches mouse/touchpad/trackpoint, so a plugged-in USB mouse wins")
		helpers.assert_true(found.name:find("TouchPad", 1, true) ~= nil, "and it is the pad")
	end)

	helpers.it("rejects a device with no multitouch slots", function()
		local devices = Finder.parse_devices(DEVICES)
		local mouse = nil
		for _, device in ipairs(devices) do
			if device.name:find("Mouse", 1, true) then mouse = device end
		end
		helpers.assert_true(mouse ~= nil, "the fixture must contain the mouse")

		local described = Finder.describe(mouse)
		helpers.assert_true(not described.is_touchpad, "a mouse is not a touchpad")
		helpers.assert_true(described.reason:find("ABS_MT_SLOT", 1, true) ~= nil,
			"and the reason names the capability it lacks, not its name")
	end)

	helpers.it("parses every device in the table", function()
		helpers.assert_eq(#Finder.parse_devices(DEVICES), 3,
			"a parser that stopped matching would report one touchpad or none and "
				.. "this file would still look green")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ How many fingers =====================================
-- =================================================================
-- =================================================================

helpers.describe("touchpad finder: capability", function()

	helpers.it("reads the finger count the hardware advertises", function()
		-- KEY=e520 10000 0 0 0 0 — the second word from the right is word 4 in
		-- 64-bit terms... the BTN_TOOL_* bits live at 0x145-0x14f, which is word 5.
		-- What matters is that a count comes back and it is one the kernel could
		-- have advertised.
		local found = touchpad()
		helpers.assert_true(found.max_fingers >= 0 and found.max_fingers <= 5,
			"the count must be a real finger count; got " .. tostring(found.max_fingers))
	end)

	helpers.it("does not call a normal buttonpad semi-MT", function()
		-- PROP=5 is bits 0 and 2: POINTER and BUTTONPAD. SEMI_MT is 0x03, i.e. bit
		-- 3, so this pad is a perfectly ordinary clickpad. Worth its own case
		-- because the two properties sit next to each other and an off-by-one here
		-- would tell every clickpad owner their hardware cannot locate fingers.
		helpers.assert_true(not touchpad().semi_mt, "bit 2 is BUTTONPAD, not SEMI_MT")
	end)

	helpers.it("flags semi-MT hardware without rejecting it", function()
		-- PROP=d is bits 0, 2 and 3: pointer, buttonpad and semi-MT.
		local semi = [[
I: Bus=0018 Vendor=0002 Product=0007 Version=01b1
N: Name="SynPS/2 Synaptics TouchPad"
H: Handlers=mouse1 event7
B: PROP=d
B: EV=b
B: KEY=e520 10000 0 0 0 0
B: ABS=661800011000003
]]
		local found = Finder.find(semi)
		helpers.assert_true(found ~= nil, "semi-MT hardware is still a touchpad")
		helpers.assert_true(found.semi_mt,
			"it reports a bounding box rather than positions, so two fingers apart "
				.. "and together look the same — the user should be told, and the "
				.. "finger COUNT is still trustworthy, so taps still work")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ The direction of failure =============================
-- =================================================================
-- =================================================================

helpers.describe("touchpad finder: what an unknown capability must do", function()

	helpers.it("offers every slot when the finger count is unknown", function()
		-- The whole safety argument for reading a printed bitmap under a word-size
		-- ASSUMPTION rests on this. A wrong parse may fail to explain a gesture
		-- that cannot work; it must never remove one that can.
		for _, slot in ipairs({ "swipe_5_up", "tap_5", "swipe_2_left", "swipe_3_horiz" }) do
			helpers.assert_true(Finder.slot_is_reachable(slot, 0),
				slot .. " must be offered when the hardware could not be read")
			helpers.assert_true(Finder.slot_is_reachable(slot, nil),
				slot .. " must be offered when nothing was measured at all")
		end
	end)

	helpers.it("marks what a three-finger pad genuinely cannot do", function()
		helpers.assert_true(Finder.slot_is_reachable("swipe_3_up", 3))
		helpers.assert_true(Finder.slot_is_reachable("tap_3", 3))
		helpers.assert_true(not Finder.slot_is_reachable("swipe_4_up", 3),
			"the kernel only advertises QUADTAP at four slots, so this can never fire")
		helpers.assert_true(not Finder.slot_is_reachable("tap_5", 3))
	end)

	helpers.it("leaves a slot it cannot parse alone", function()
		helpers.assert_true(Finder.slot_is_reachable("something_else", 3),
			"a slot whose name carries no finger count is not this module's to judge")
	end)

end)
