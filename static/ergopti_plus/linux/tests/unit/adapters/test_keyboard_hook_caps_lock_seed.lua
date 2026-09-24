--- tests/unit/adapters/test_keyboard_hook_caps_lock_seed.lua

--- ==============================================================================
--- MODULE: CapsLock Already On When The Keyboard Is Acquired
--- DESCRIPTION:
--- A fresh XKB state starts unlocked and learned CapsLock only from presses, so
--- a daemon started with CapsLock on read triggers in the wrong case and — once
--- the injector began releasing a locked CapsLock around replacements — would
--- have typed them inverted. The hook now seeds the capture state from the LED
--- at every acquisition.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEY_CAPSLOCK_XKB = 58 + 8

--- Loads the hook over an evdev backend reporting `led_byte` and a capture
--- backend that records every key update.
--- @param led_byte integer
--- @return table hook, table updates
local function load(led_byte)
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
		create = function() return {} end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function() return nil end,
		sym_utf8 = function() return nil end,
		update_key = function(_, keycode, direction) updates[#updates + 1] = { keycode, direction } end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		compose_utf8 = function() return nil end,
		compose_reset = function() end,
	})
	assert(Capture.load("keymap", "C"))
	package.loaded["adapters.keyboard_hook"] = nil
	local hook = require("adapters.keyboard_hook")
	Evdev.open("/dev/input/event3", "keyboard:/dev/input/event3")
	return hook, updates
end

helpers.describe("keyboard_hook: CapsLock is seeded at acquisition", function()

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
		local _, calls = source:gsub("\n%s*_seed_caps_lock%(_devices%[1%]%)", "")
		helpers.assert_eq(calls, 2, "seeded after start() and after the watchdog re-acquire")
	end)

end)
