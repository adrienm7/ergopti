--- tests/unit/adapters/test_keyboard_hook_safety.lua

--- ==============================================================================
--- MODULE: Keyboard Hook — shortcuts, AltGr, and the pointer
--- DESCRIPTION:
--- Three properties that decide whether characters reach the typing buffer at
--- all, and one that decides whether the buffer still describes where the caret
--- is.
---
--- WHY EACH ONE IS A DEFECT AND NOT A REFINEMENT:
---
--- 1. Ctrl+S is not the letter S. The layout resolves a character for that key
---    whether or not Ctrl is down, so every shortcut a user pressed went into the
---    typing buffer. An expansion could then fire against text nobody typed, and
---    erase characters that were never there.
---
--- 2. AltGr is not Alt. AltGr selects level 3 of the layout, which on a French
---    keyboard is where é, € and « live; Alt starts a shortcut. Both are
---    KEY_*ALT, and the hook used to fold them into one flag — so suppressing
---    shortcuts and typing accents were the same switch, and only one of them
---    could be on.
---
--- 3. A held Shift changes what an injection types. Under a grab the application
---    has already seen the press we re-emitted, so it believes Shift is down: an
---    injected "e" arrives as "E". Waiting for the user to let go cannot work —
---    the release event is in the kernel buffer the injection is not reading.
---
--- 4. A click moves the caret. Every character buffered before it describes a
---    position the user has left, so the next expansion would erase text
---    belonging to whatever is under the cursor now.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1

--- One EV_KEY event.
--- @param code integer
--- @param value integer
--- @return table
local function key(code, value)
	return { type = EV_KEY, code = code, value = value }
end

--- Drives events through the hook and collects what the domain saw.
--- @param events table
--- @return table chars, table keys
local function drive(events)
	local kh = helpers.load_module("adapters.keyboard_hook")
	local chars, keys = {}, {}
	kh._test_drive(events, {
		onChar    = function(ch) chars[#chars + 1] = ch end,
		onKey     = function(name) keys[#keys + 1] = name end,
		onEmitRaw = function() end,
	}, true)
	return chars, keys
end





-- =================================================================
-- =================================================================
-- ======= 1/ A shortcut is not text ===============================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: modifiers that start a shortcut", function()

	helpers.it("keeps Ctrl+key out of the typing buffer", function()
		local codes = helpers.load_module("infra.evdev_codes")
		local chars, keys = drive({
			key(codes.KEY_LEFTCTRL, 1),
			key(30, 1),                    -- KEY_A, while Ctrl is down
			key(codes.KEY_LEFTCTRL, 0),
			key(30, 1),                    -- KEY_A again, on its own
		})
		helpers.assert_eq(chars, { "a" },
			"only the unmodified press is text; the shortcut fed the buffer a letter "
				.. "the user never typed, and an expansion could then fire against it")
		helpers.assert_eq(keys, { "shortcut" },
			"and the shortcut is reported, so the caller can drop a buffer whose caret "
				.. "has almost certainly moved")
	end)

	helpers.it("keeps Alt+key out too", function()
		local codes = helpers.load_module("infra.evdev_codes")
		local chars = drive({
			key(codes.KEY_LEFTALT, 1),
			key(15, 1),                    -- Tab, i.e. Alt+Tab
			key(30, 1),
			key(codes.KEY_LEFTALT, 0),
		})
		helpers.assert_eq(chars, {}, "nothing typed during Alt is text")
	end)

	helpers.it("keeps the Super key out", function()
		local codes = helpers.load_module("infra.evdev_codes")
		local chars = drive({
			key(codes.KEY_LEFTMETA, 1),
			key(30, 1),
			key(codes.KEY_LEFTMETA, 0),
		})
		helpers.assert_eq(chars, {}, "Super+A opens a launcher; it does not type an A")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ AltGr is not Alt =====================================
-- =================================================================
-- =================================================================

helpers.describe("keyboard_hook: AltGr produces text", function()

	helpers.it("classifies the right Alt key as a layout modifier", function()
		local codes = helpers.load_module("infra.evdev_codes")
		helpers.assert_eq(codes.MODIFIER_OF[codes.KEY_RIGHTALT], "altgr",
			"AltGr selects level 3 of the layout — é, € and « on a French keyboard")
		helpers.assert_eq(codes.MODIFIER_OF[codes.KEY_LEFTALT], "alt",
			"left Alt starts a shortcut, and folding the two together makes "
				.. "'suppress shortcuts' and 'type accents' the same switch")
	end)

	helpers.it("still delivers characters typed while AltGr is held", function()
		local codes = helpers.load_module("infra.evdev_codes")
		local chars = drive({
			key(codes.KEY_RIGHTALT, 1),
			key(30, 1),
			key(codes.KEY_RIGHTALT, 0),
		})
		helpers.assert_eq(chars, { "a" },
			"AltGr must not suppress the keystroke; on a French layout that is how "
				.. "every level-3 character would be lost")
	end)

	helpers.it("reports AltGr as a modifier an injection has to neutralise", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local codes = helpers.load_module("infra.evdev_codes")
		kh._test_drive({ key(codes.KEY_RIGHTALT, 1) }, { onEmitRaw = function() end }, true)
		helpers.assert_eq(kh.held_text_modifiers(), { "altgr" },
			"an injection under a held AltGr types level-3 characters instead of the "
				.. "replacement, so it has to know")
	end)

	helpers.it("reports a held Shift, and nothing once released", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local codes = helpers.load_module("infra.evdev_codes")
		kh._test_drive({ key(codes.KEY_LEFTSHIFT, 1) }, { onEmitRaw = function() end }, true)
		helpers.assert_eq(kh.held_text_modifiers(), { "shift" }, "held")
		kh._test_drive({ key(codes.KEY_LEFTSHIFT, 0) }, { onEmitRaw = function() end }, true)
		helpers.assert_eq(kh.held_text_modifiers(), {}, "and released")
	end)

	helpers.it("never reports a shortcut modifier, because one cannot be held here", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local codes = helpers.load_module("infra.evdev_codes")
		kh._test_drive({ key(codes.KEY_LEFTCTRL, 1) }, { onEmitRaw = function() end }, true)
		helpers.assert_eq(kh.held_text_modifiers(), {},
			"an expansion cannot fire while Ctrl is down — the character never "
				.. "reached the engine — so there is nothing for an injection to "
				.. "neutralise, and neutralising it would release a key the user holds")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ An injection neutralises what is held ================
-- =================================================================
-- =================================================================

helpers.describe("injector: a held modifier does not reach the replacement", function()

	helpers.it("releases Shift for the injection and presses it back", function()
		local codes = helpers.load_module("infra.evdev_codes")

		-- Hold Shift on the real hook, so the injector reads a real state rather
		-- than a stub of the question it is asking.
		local kh = helpers.load_module("adapters.keyboard_hook")
		kh._test_drive({ key(codes.KEY_LEFTSHIFT, 1) }, { onEmitRaw = function() end }, true)
		package.loaded["adapters.keyboard_hook"] = kh

		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test({ e = { keycode = 18, level = 1, mods = {} } })
		package.loaded["adapters.keyboard_layout"] = layout

		local injector = helpers.load_module("modules.hotstrings.injector")
		local events = {}
		injector._set_uinput({
			is_open = function() return true end,
			emit = function(code, value)
				events[#events + 1] = string.format("%d:%d", code, value)
				return true
			end,
		})
		injector._set_nanosleep_for_test(function() end)
		injector.inject(0, "e")

		helpers.assert_eq(table.concat(events, " "), string.format(
			"%d:0 18:1 18:0 %d:1", codes.KEY_LEFTSHIFT, codes.KEY_LEFTSHIFT),
			"Shift is released first, the character is typed unmodified, and Shift is "
				.. "put back — a user still holding it keeps holding it")

		-- Leave no state behind for the next file.
		kh._test_drive({ key(codes.KEY_LEFTSHIFT, 0) }, { onEmitRaw = function() end }, true)
		injector._set_uinput(nil)
		injector._set_nanosleep_for_test(nil)
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The pointer is watched, never grabbed ================
-- =================================================================
-- =================================================================

helpers.describe("device_finder: choosing a pointer", function()

	--- Builds one /proc/bus/input/devices block.
	--- @param opts table
	--- @return string
	local function block(opts)
		return table.concat({
			"I: Bus=0003 Vendor=046d Product=c52b Version=0111",
			'N: Name="' .. opts.name .. '"',
			"S: Sysfs=" .. opts.sysfs,
			"H: Handlers=" .. opts.handlers,
			"B: EV=" .. opts.ev,
		}, "\n") .. "\n\n"
	end

	local KEYBOARD = block({
		name = "Logitech USB Keyboard", sysfs = "/devices/pci0000:00/input/input3",
		ev = "120013", handlers = "sysrq kbd event3",
	})
	-- EV=17 is EV_SYN|EV_KEY|EV_REL: buttons and a relative axis.
	local MOUSE = block({
		name = "Logitech USB Optical Mouse", sysfs = "/devices/pci0000:00/input/input5",
		ev = "17", handlers = "mouse0 event5",
	})
	-- EV=b is EV_SYN|EV_KEY|EV_ABS: a touchpad.
	local TOUCHPAD = block({
		name = "SynPS/2 Synaptics TouchPad", sysfs = "/devices/platform/i8042/input/input7",
		ev = "b", handlers = "mouse1 event7",
	})
	local OUR_INJECTOR = block({
		name = "Ergopti Virtual Keyboard", sysfs = "/devices/virtual/input/input21",
		ev = "17", handlers = "mouse2 event21",
	})

	--- @param text string
	--- @return string|nil
	local function select_from(text)
		local finder = helpers.load_module("modules.hotstrings.device_finder")
		return finder.select_pointer(finder.parse_devices(text))
	end

	helpers.it("finds a mouse and not the keyboard", function()
		helpers.assert_eq(select_from(KEYBOARD .. MOUSE), "/dev/input/event5",
			"a keyboard has buttons and no axis; only a pointer has both")
	end)

	helpers.it("accepts a touchpad, which reports an absolute axis", function()
		helpers.assert_eq(select_from(KEYBOARD .. TOUCHPAD), "/dev/input/event7",
			"a laptop with no mouse still has a caret that moves when it is tapped")
	end)

	helpers.it("never picks a synthetic device", function()
		helpers.assert_eq(select_from(OUR_INJECTOR), nil,
			"our own uinput device advertises buttons; watching it would mean "
				.. "reacting to our own injections")
	end)

	helpers.it("answers nothing when the machine has no pointer", function()
		helpers.assert_eq(select_from(KEYBOARD), nil,
			"a headless machine has none, and that is not an error — it only means "
				.. "a click cannot reset the buffer")
	end)

end)
