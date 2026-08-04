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
--- The second half is the remap daemon. Its output device carries POST-remap
--- keycodes — the codes the application actually receives — and reading anything
--- else means resolving characters the user never typed. It is itself a virtual
--- device, so a blanket "skip virtual" rule would drop it: the preference has to
--- be checked before the exclusion, and these tests pin that order.
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

helpers.describe("device_finder: the remap output device is chosen by name", function()

	helpers.it("prefers it over the physical keyboard, because its codes are post-remap", function()
		local path, reason = select_from(PHYSICAL_KEYBOARD .. REMAP_OUTPUT)
		helpers.assert_eq(path, "/dev/input/event20",
			"the remap daemon's output carries the keycodes the application receives; "
				.. "grabbing the physical device resolves characters the user never typed")
		helpers.assert_eq(reason, "remap_output",
			"the choice must be reported as a rule, not as the ranking fallback")
	end)

	helpers.it("finds it even when it enumerates after every other device", function()
		local path = select_from(POWER_BUTTON .. PHYSICAL_KEYBOARD .. MOUSE .. REMAP_OUTPUT)
		helpers.assert_eq(path, "/dev/input/event20",
			"enumeration order must not decide which stream the engine reads")
	end)

	helpers.it("is not dropped by the virtual-device exclusion it also matches", function()
		-- The remap output IS a uinput device, registered under /devices/virtual/
		-- like our own injector. If the exclusion ran first it would be skipped and
		-- the daemon would silently fall back to pre-remap keycodes.
		local path, reason = select_from(REMAP_OUTPUT)
		helpers.assert_eq(path, "/dev/input/event20",
			"the name preference must be evaluated before the synthetic-device exclusion")
		helpers.assert_eq(reason, "remap_output", "and it must be the rule that reports the choice")
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
		helpers.assert_eq(devices[1].name, "kanata", "the name drives the preference")
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
