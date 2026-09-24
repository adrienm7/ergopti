--- tests/unit/modules/hotstrings/test_injector_held_terminator.lua

--- ==============================================================================
--- MODULE: The Terminator Still Held During An Expansion
--- DESCRIPTION:
--- An expansion fires on the terminator's key-DOWN, which the grabbed hook has
--- already forwarded, so while the replacement is typed that key is still down
--- on the virtual keyboard. The kernel drops a key-down for a key that is
--- already down: "adn " reached the desktop as "ADN", the replayed space lost,
--- and the next word glued onto the replacement. Measured through a real kernel
--- by tests/hardware/run_daemon_live.lua.
---
--- The hook now reports the non-modifier keys it forwarded as held, and every
--- output transaction releases them before its first key.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1
local KEY_SPACE = 57
local KEY_BACKSPACE = 14
local KEY_LEFTSHIFT = 42
local KEY_A = 30

-- =========================================
-- =========================================
-- ======= 1/ The hook reports it ==========
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: the forwarded keys still held", function()

	helpers.it("reports the terminator while its key-down is being handled", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local seen = {}
		kh._test_drive({
			{ type = EV_KEY, code = KEY_LEFTSHIFT, value = 1 },
			{ type = EV_KEY, code = KEY_A, value = 1 },
			{ type = EV_KEY, code = KEY_A, value = 0 },
			{ type = EV_KEY, code = KEY_LEFTSHIFT, value = 0 },
			{ type = EV_KEY, code = KEY_SPACE, value = 1 },
		}, {
			onChar = function(ch)
				if ch == " " then seen = kh.held_forwarded_keys() end
			end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_eq(#seen, 1, "only the space is still down; shift is a modifier and A was released")
		helpers.assert_eq(seen[1], KEY_SPACE)
	end)

end)

-- =========================================
-- =========================================
-- ======= 2/ The injector releases it ===
-- =========================================
-- =========================================

--- Loads the injector over a hook that reports `held` and a recording channel.
--- @param held table evdev keycodes the hook reports as forwarded and held.
--- @return table injector, table channel
local function load(held)
	local real_hook = package.loaded["adapters.keyboard_hook"]
	package.loaded["adapters.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end,
		held_forwarded_keys = function() return held end,
	}
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test({ ["x"] = { keycode = 45, level = 1, mods = {} } })
	local channel = { emitted = {} }
	channel.is_open = function() return true end
	channel.emit = function(code, value)
		channel.emitted[#channel.emitted + 1] = { code = code, value = value }
		return true
	end
	channel.sync = function() return true end
	package.loaded["modules.hotstrings.injector"] = nil
	local injector = require("modules.hotstrings.injector")
	injector._set_uinput(channel)
	injector._set_nanosleep_for_test(function() end)
	return injector, channel, function()
		package.loaded["adapters.keyboard_hook"] = real_hook
		package.loaded["modules.hotstrings.injector"] = nil
	end
end

--- Index of the first event matching code and value, or nil.
local function first(channel, code, value)
	for index, event in ipairs(channel.emitted) do
		if event.code == code and event.value == value then return index end
	end
	return nil
end

helpers.describe("injector: a held terminator is released before the replacement", function()

	helpers.it("releases the space before the first backspace", function()
		local injector, channel, restore = load({ KEY_SPACE })
		injector.inject(1, "x")
		restore()
		local release = first(channel, KEY_SPACE, 0)
		local erase = first(channel, KEY_BACKSPACE, 1)
		helpers.assert_true(release ~= nil, "the held space must be released")
		helpers.assert_true(erase ~= nil and release < erase,
			"before the erase, so the space replayed after the text is a fresh key-down")
		helpers.assert_eq(first(channel, KEY_SPACE, 1), nil,
			"and never pressed again: the user typed it once")
	end)

	helpers.it("releases nothing when no key is held", function()
		local injector, channel, restore = load({})
		injector.inject(1, "x")
		restore()
		helpers.assert_eq(first(channel, KEY_SPACE, 0), nil)
	end)

end)
