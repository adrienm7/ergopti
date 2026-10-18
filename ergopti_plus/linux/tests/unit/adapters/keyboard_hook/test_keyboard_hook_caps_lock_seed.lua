--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_caps_lock_seed.lua

--- ==============================================================================
--- MODULE: Lock State When The Keyboard Is Acquired
--- DESCRIPTION:
--- A fresh XKB state starts unlocked and learned CapsLock only from presses, so
--- a daemon started with CapsLock on read triggers in the wrong case and — once
--- the injector began releasing a locked CapsLock around replacements — would
--- have typed them inverted. The hook now seeds the capture state from the LED
--- at every acquisition. NumLock must also be restored or keypad digits stop
--- reaching the matcher after an unrelated source change. These cases use the
--- real capture consumer with a controlled stateful XKB backend; the hardware
--- probe independently checks native kernel LEDs and libxkbcommon output.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEY_CAPSLOCK_XKB = 58 + 8
local KEY_NUMLOCK_XKB = 69 + 8
local KEY_SCROLLLOCK_XKB = 70 + 8

--- Loads the hook over an evdev backend reporting `led_byte` and a capture
--- backend that records every key update.
--- @param led_byte integer
--- @param failing_code integer|nil Controlled refused native XKB code.
--- @return table hook, table updates, table capture
local function load(led_byte, failing_code)
	local Evdev = helpers.load_module("adapters.evdev_reader")
	Evdev._set_backend({
		open = function() return 7 end,
		ioctl = function() return true end,
		read = function() return nil end,
		poll = function() return false end,
		close = function() end,
		read_bits = function(_, request, count)
			if request % 0x100 == Evdev.EVIOCGLED_NR then
				return string.char(led_byte) .. string.rep("\0", count - 1)
			end
			return string.rep("\0", count)
		end,
	})
	local Capture = helpers.load_module("adapters.xkb_capture")
	local updates = {}
	Capture._set_backend({
		create = function() return { num = false } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function(session, code) return code == 79 + 8 and (session.num and "1" or "") or nil end,
		sym_utf8 = function() return nil end,
		update_key = function(session, keycode, direction)
			if keycode == failing_code then error("controlled lock capture failure") end
			updates[#updates + 1] = { keycode, direction }
			if keycode == KEY_NUMLOCK_XKB and direction == 1 then session.num = not session.num end
		end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		compose_utf8 = function() return nil end,
		compose_reset = function() end,
	})
	assert(Capture.load("keymap", "C"))
	package.loaded["adapters.keyboard_hook"] = nil
	local hook = require("adapters.keyboard_hook")
	Evdev.open("/dev/input/event3", "keyboard:/dev/input/event3")
	return hook, updates, Capture
end

helpers.describe("keyboard_hook: lock state is seeded at acquisition", function()

	helpers.it("(linux-numlock-seed) restores keypad text from a lit NumLock LED", function()
		local hook, _, capture = load(0x01)
		helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/event3"))
		local text = capture.process(79, 1)
		helpers.assert_eq(text, "1", "the real capture consumer must resolve KP1 as text after acquisition")
	end)

	helpers.it("(linux-numlock-seed) keeps keypad navigation when the NumLock LED is off", function()
		local hook, _, capture = load(0x00)
		helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/event3"))
		helpers.assert_eq(capture.process(79, 1), "")
	end)

	helpers.it("(linux-numlock-seed) restores independent Caps Num and Scroll LEDs once", function()
		local hook, updates = load(0x07)
		helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/event3"))
		helpers.assert_eq(updates, {
			{ KEY_NUMLOCK_XKB, 1 }, { KEY_NUMLOCK_XKB, 0 },
			{ KEY_CAPSLOCK_XKB, 1 }, { KEY_CAPSLOCK_XKB, 0 },
			{ KEY_SCROLLLOCK_XKB, 1 }, { KEY_SCROLLLOCK_XKB, 0 },
		})
	end)

	helpers.it("(linux-numlock-seed) refuses an unsuccessful native lock capture update", function()
		local hook = load(0x01, KEY_NUMLOCK_XKB)
		helpers.assert_eq(hook._seed_caps_lock_for_test("/dev/input/event3"), false)
	end)

	helpers.it("(linux-numlock-seed) does not toggle a held NumLock twice during report recovery", function()
		local hook = load(0x01)
		local chars = {}
		hook._test_drive({ { type = 0, code = 3, value = 0 }, { type = 0, code = 0, value = 0 },
			{ type = 1, code = 79, value = 1 }, { type = 1, code = 79, value = 0 } }, {
			liveXkb = true,
			keyState = function(count)
				local bytes = {}; for index = 1, count do bytes[index] = 0 end
				bytes[math.floor(69 / 8) + 1] = 2 ^ (69 % 8)
				local encoded = {}; for index, byte in ipairs(bytes) do encoded[index] = string.char(byte) end
				return table.concat(encoded)
			end,
			ledState = function(count) return "\1" .. string.rep("\0", count - 1) end,
			onChar = function(char) chars[#chars + 1] = char end,
		}, true)
		helpers.assert_eq(table.concat(chars), "1", "held-state replay and LED seeding must apply one lock toggle")
	end)

	helpers.it("locks the capture state when the LED is on", function()
		local hook, updates = load(0x02) -- bit LED_CAPSL (1)
		helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/event3"))
		helpers.assert_eq(updates, { { KEY_CAPSLOCK_XKB, 1 }, { KEY_CAPSLOCK_XKB, 0 } },
			"one CapsLock press and release brings the fresh state to the LED's answer")
	end)

	helpers.it("leaves it unlocked when the LED is off", function()
		local hook, updates = load(0x00)
		helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/event3"))
		helpers.assert_eq(#updates, 0)
	end)

	helpers.it("runs after both kinds of acquisition", function()
		-- start() and the hotplug re-acquire each reset the capture state.
		local fh = assert(io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local _, calls = source:gsub("= _locks%.seed%(_devices%[1%]%)", "")
		helpers.assert_eq(calls, 2, "seeded after start() and after the watchdog re-acquire")
	end)

end)
