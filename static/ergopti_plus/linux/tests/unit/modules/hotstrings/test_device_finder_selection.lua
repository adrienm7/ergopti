--- tests/unit/modules/hotstrings/test_device_finder_selection.lua

--- ==============================================================================
--- MODULE: Device Finder Selection
--- DESCRIPTION:
--- Which /dev/input/eventN the daemon grabs, driven from a fixture copy of
--- /proc/bus/input/devices.
---
--- WHY THIS IS THE ASSERTION:
--- The finder ranked devices by name, preferring anything containing "keyboard"
--- or "kbd". Our own injection device is called "Ergopti Virtual Keyboard", so it
--- did not merely fail to be excluded — it sat in the PREFERRED tier, above the
--- physical keyboard. Whenever it enumerated first the daemon grabbed its own
--- output: every injected character came back in as user input and was matched
--- again. Nothing could catch that, because the module read /proc directly and
--- exposed no seam, so there was no way to hand it a device list at all.
---
--- A remap daemon's output (kanata's) used to win outright. The tap-holds now run in this daemon on the physical keyboard, so
--- that output is one more uinput device and is excluded like any injector.
---
--- The fixtures are real /proc/bus/input/devices syntax, including the `S: Sysfs=`
--- line the parser used to discard. That line is the kernel's own answer to "is
--- this device real", and it is what makes the exclusion survive an injector this
--- code has never heard of.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds one /proc/bus/input/devices block.
--- @param opts table {name, sysfs, ev, handlers}
--- @return string
local function block(opts)
	return table.concat({
		"I: Bus=0003 Vendor=046d Product=c52b Version=0111",
		'N: Name="' .. opts.name .. '"',
		"P: Phys=usb-0000:00:14.0-1/input0",
		"S: Sysfs=" .. opts.sysfs,
		"U: Uniq=",
		"H: Handlers=" .. opts.handlers,
		"B: EV=" .. opts.ev,
	}, "\n") .. "\n\n"
end

local PHYSICAL_KEYBOARD = block({
	name     = "Logitech USB Keyboard",
	sysfs    = "/devices/pci0000:00/0000:00:14.0/usb1/1-1/input/input3",
	ev       = "120013",
	handlers = "sysrq kbd event3 leds",
})

local LAPTOP_KEYBOARD = block({
	name     = "AT Translated Set 2 keyboard",
	sysfs    = "/devices/platform/i8042/serio0/input/input2",
	ev       = "120013",
	handlers = "sysrq kbd event2 leds",
})

local REMAP_OUTPUT = block({
	name     = "kanata",
	sysfs    = "/devices/virtual/input/input20",
	ev       = "120013",
	handlers = "sysrq kbd event20 leds",
})

local OUR_INJECTOR = block({
	name     = "Ergopti Virtual Keyboard",
	sysfs    = "/devices/virtual/input/input21",
	ev       = "100003",
	handlers = "sysrq kbd event21",
})

local THIRD_PARTY_INJECTOR = block({
	name     = "ydotoold virtual device",
	sysfs    = "/devices/virtual/input/input22",
	ev       = "100003",
	handlers = "sysrq kbd event22",
})

local POWER_BUTTON = block({
	name     = "Power Button",
	sysfs    = "/devices/LNXSYSTM:00/LNXPWRBN:00/input/input0",
	ev       = "3",
	handlers = "kbd event0",
})

-- EV=17 is EV_SYN|EV_KEY|EV_REL: a mouse really does report EV_KEY, for its
-- buttons. It is here as a device the ranking must not mistake for a keyboard,
-- not as one the capability filter rejects.
local MOUSE = block({
	name     = "Logitech USB Optical Mouse",
	sysfs    = "/devices/pci0000:00/0000:00:14.0/usb1/1-2/input/input5",
	ev       = "17",
	handlers = "mouse0 event5",
})

-- EV=21 is EV_SYN|EV_SW — a lid or headphone-jack switch. No EV_KEY at all, so
-- it is the shape the capability filter is for.
local LID_SWITCH = block({
	name     = "Lid Switch",
	sysfs    = "/devices/LNXSYSTM:00/PNP0C0D:00/input/input1",
	ev       = "21",
	handlers = "event1",
})

--- Selects from a fixture, returning the path and the rule that chose it.
--- @param text string Fixture file content.
--- @return string|nil, string|nil
local function select_from(text)
	local finder = helpers.load_module("modules.hotstrings.device_finder")
	return finder.select(finder.parse_devices(text))
end





-- =================================================================
-- =================================================================
-- ======= 1/ The remap daemon's output wins outright ==============
-- =================================================================
-- =================================================================

helpers.describe("device_finder: a remap daemon's output is not read", function()

	helpers.it("takes the physical keyboard, not kanata's virtual output", function()
		local path, reason = select_from(PHYSICAL_KEYBOARD .. REMAP_OUTPUT)
		helpers.assert_eq(path, "/dev/input/event3",
			"the tap-holds run on the physical keyboard; the remap output is an injector")
		helpers.assert_eq(reason, "named_keyboard")
	end)

	helpers.it("finds no keyboard in a remap output alone", function()
		local path = select_from(REMAP_OUTPUT)
		helpers.assert_nil(path, "a virtual device is never the keyboard")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Our own injections are never read back ===============
-- =================================================================
-- =================================================================

helpers.describe("device_finder: synthetic devices are excluded", function()

	helpers.it("never grabs our own uinput device, even though its name says keyboard", function()
		-- The regression. "Ergopti Virtual Keyboard" contains "keyboard", so the
		-- name heuristic put it in the preferred tier; listing it first is what a
		-- machine that started the daemon before plugging the keyboard in does.
		local path, reason = select_from(OUR_INJECTOR .. PHYSICAL_KEYBOARD)
		helpers.assert_eq(path, "/dev/input/event3",
			"grabbing our own injection device feeds every expansion back into the "
				.. "engine as user input")
		helpers.assert_eq(reason, "named_keyboard", "and the physical keyboard is what is left")
	end)

	helpers.it("never grabs a third-party injector", function()
		local path = select_from(THIRD_PARTY_INJECTOR .. PHYSICAL_KEYBOARD)
		helpers.assert_eq(path, "/dev/input/event3",
			"another daemon's uinput device is somebody else's synthetic stream")
	end)

	helpers.it("returns nothing rather than a synthetic device when that is all there is", function()
		local path, reason = select_from(OUR_INJECTOR .. THIRD_PARTY_INJECTOR)
		helpers.assert_eq(path, nil,
			"a daemon with no real input to read must say so; picking its own output "
				.. "produces an infinite expansion loop instead of a startup error")
		helpers.assert_eq(reason, nil, "and report no rule, since none fired")
	end)

	helpers.it("classifies by sysfs, so an injector with an innocent name is still excluded", function()
		local disguised = block({
			name     = "Generic Keyboard",
			sysfs    = "/devices/virtual/input/input30",
			ev       = "120013",
			handlers = "sysrq kbd event30",
		})
		local path = select_from(disguised .. PHYSICAL_KEYBOARD)
		helpers.assert_eq(path, "/dev/input/event3",
			"the name list only knows the injectors we know; /devices/virtual/ is the "
				.. "kernel's own answer and covers the ones we do not")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Ranking among real devices ==========================
-- =================================================================
-- =================================================================

helpers.describe("device_finder: ranking when no remap daemon is running", function()

	helpers.it("returns every physical keyboard when no consolidated remap output exists", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		local paths, reason = finder.select_keyboards(
			finder.parse_devices(PHYSICAL_KEYBOARD .. LAPTOP_KEYBOARD .. MOUSE))
		helpers.assert_eq(paths, { "/dev/input/event2", "/dev/input/event3" },
			"a laptop keyboard and a USB keyboard are independent streams; selecting "
				.. "only one lets the other bypass hotstrings and metrics")
		helpers.assert_eq(reason, "named_keyboards")
	end)

	helpers.it("prefers a keyboard-named device over another EV_KEY device", function()
		local path, reason = select_from(POWER_BUTTON .. PHYSICAL_KEYBOARD)
		helpers.assert_eq(path, "/dev/input/event3",
			"the power button reports EV_KEY too; it is not what the user types on")
		helpers.assert_eq(reason, "named_keyboard", "and the rule that chose it is the name")
	end)

	helpers.it("falls back to any EV_KEY device when none is named like a keyboard", function()
		local path, reason = select_from(POWER_BUTTON)
		helpers.assert_eq(path, "/dev/input/event0",
			"a machine whose keyboard is not called one is still worth starting on")
		helpers.assert_eq(reason, "any_key_device", "reported as the fallback it is")
	end)

	helpers.it("ignores devices with no EV_KEY capability", function()
		local path = select_from(LID_SWITCH)
		helpers.assert_eq(path, nil,
			"a switch reports no keys, so there is no character stream to read from it")
	end)

	helpers.it("does not mistake a mouse for the keyboard when a keyboard is present", function()
		local path, reason = select_from(MOUSE .. PHYSICAL_KEYBOARD)
		helpers.assert_eq(path, "/dev/input/event3",
			"a mouse reports EV_KEY for its buttons and enumerates before the keyboard "
				.. "on plenty of machines; the name is what separates them")
		helpers.assert_eq(reason, "named_keyboard", "chosen by name, not by enumeration order")
	end)

	helpers.it("ignores an EV_KEY device with no eventN handler", function()
		local no_event = block({
			name     = "Phantom Keyboard",
			sysfs    = "/devices/pci0000:00/input/input9",
			ev       = "120013",
			handlers = "kbd leds",
		})
		local path = select_from(no_event)
		helpers.assert_eq(path, nil,
			"without an eventN node there is no character device to open")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The parser reads what the selection needs ===========
-- =================================================================
-- =================================================================

helpers.describe("device_finder: parse_devices keeps the fields the rules depend on", function()

	helpers.it("captures the sysfs line the old parser discarded", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		local devices = finder.parse_devices(REMAP_OUTPUT)
		helpers.assert_eq(#devices, 1, "one block in, one descriptor out")
		helpers.assert_eq(devices[1].sysfs, "/devices/virtual/input/input20",
			"the exclusion is built on this field; dropping it was why the rule could "
				.. "not be written at all")
		helpers.assert_eq(devices[1].name, "kanata")
		helpers.assert_eq(devices[1].ev_mask, 0x120013, "EV= is hexadecimal")
	end)

	helpers.it("flushes the final block when the file does not end with a blank line", function()
		local truncated = PHYSICAL_KEYBOARD:gsub("\n\n$", "\n")
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		helpers.assert_eq(#finder.parse_devices(truncated), 1,
			"/proc does end each block with a blank line, but a reader that depends on "
				.. "it loses the last device on any kernel that stops doing so")
	end)

	helpers.it("returns an empty list for input that is not a string", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		helpers.assert_eq(#finder.parse_devices(nil), 0,
			"an unreadable /proc must produce no devices, not a crash on the input path")
	end)

end)




helpers.describe("device_finder: a path must be able to produce key events", function()

	helpers.it("accepts an evdev node whose EV mask carries EV_KEY", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		local devices = finder.parse_devices(PHYSICAL_KEYBOARD)
		local ok = finder.is_key_device("/dev/input/event3", devices)
		helpers.assert_true(ok, "a real keyboard node must be accepted")
	end)

	helpers.it("refuses a node that reports no EV_KEY", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		-- EV=21 is EV_SYN|EV_SW: a lid switch. It is an evdev node, it is readable,
		-- and it can never emit a keystroke.
		local devices = finder.parse_devices(block({
			name     = "Lid Switch",
			sysfs    = "/devices/LNXSYSTM:00/PNP0C0D:00/input/input1",
			ev       = "21",
			handlers = "event1",
		}))
		local ok, why = finder.is_key_device("/dev/input/event1", devices)
		helpers.assert_true(not ok, "a switch is not a keyboard")
		helpers.assert_true(type(why) == "string" and why:find("EV_KEY", 1, true) ~= nil,
			"and the reason must name the missing capability, not just say no")
	end)

	helpers.it("refuses a path that is not an evdev node at all", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		-- The case a real Linux runner found: /dev/null is readable, so the only
		-- check that existed passed, the hook reported itself running, and the
		-- daemon waited forever for events that cannot arrive.
		local ok, why = finder.is_key_device("/dev/null", {})
		helpers.assert_true(not ok, "/dev/null must be refused")
		helpers.assert_true(type(why) == "string" and why:find("eventN", 1, true) ~= nil,
			"and the reason must say what kind of path was expected")
	end)

	helpers.it("refuses an eventN node the kernel does not list", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		local ok, why = finder.is_key_device("/dev/input/event99", {})
		helpers.assert_true(not ok, "a node absent from /proc cannot be verified, so it is refused")
		helpers.assert_true(type(why) == "string" and why:find("not listed", 1, true) ~= nil,
			"and the reason must distinguish 'absent' from 'not a keyboard'")
	end)

	helpers.it("refuses nil and the empty string without crashing", function()
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		helpers.assert_true(not (finder.is_key_device(nil, {})), "nil is not a device")
		helpers.assert_true(not (finder.is_key_device("", {})), "nor is the empty string")
	end)

end)
