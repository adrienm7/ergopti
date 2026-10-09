--- tests/unit/modules/hotstrings/test_injector_caps_lock.lua

--- ==============================================================================
--- MODULE: A Replacement Typed Under CapsLock
--- DESCRIPTION:
--- The layout plan is the chord for each character with CapsLock OFF. Typed
--- while CapsLock was locked, every letter inverted: "Bonjour" arrived as
--- "bONJOUR", and on Ergopti, whose type gives Lock its own level, 69 of 100
--- characters came out wrong. The injector now releases the lock around the
--- typed replacement and restores it, including when an emit fails.
---
--- What a real libxkbcommon state makes of these events is proven in
--- tests/hardware/run_layout_resolution.lua; here, the event sequence.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEY_CAPSLOCK = 58
local LAYOUT = {
	["B"] = { keycode = 48, level = 2, mods = { "shift" } },
	["o"] = { keycode = 24, level = 1, mods = {} },
}

--- Loads the injector over a CapsLock state and a recording channel.
--- @param locked boolean
--- @param fail_after integer|nil Refuse every emit after this many.
--- @return table injector, table channel
local function load(locked, fail_after)
	package.loaded["adapters.xkb_capture"] = nil
	local Capture = require("adapters.xkb_capture")
	Capture.caps_locked = function() return locked end
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(LAYOUT)
	local channel = { emitted = {} }
	channel.is_open = function() return true end
	channel.emit = function(code, value)
		if fail_after and #channel.emitted >= fail_after then return false end
		channel.emitted[#channel.emitted + 1] = { code = code, value = value }
		return true
	end
	channel.sync = function() return true end
	package.loaded["modules.hotstrings.injector"] = nil
	local injector = require("modules.hotstrings.injector")
	injector._set_uinput(channel)
	injector._set_nanosleep_for_test(function() end)
	return injector, channel
end

--- The CapsLock presses among the emitted events.
local function caps_presses(channel)
	local count = 0
	for _, event in ipairs(channel.emitted) do
		if event.code == KEY_CAPSLOCK and event.value == 1 then count = count + 1 end
	end
	return count
end

helpers.describe("injector: CapsLock does not invert the replacement", function()

	helpers.it("releases the lock before typing and restores it after", function()
		local injector, channel = load(true)
		injector.inject(0, "Bo")
		-- Positions, not absolute indexes: the output transaction may first
		-- release modifiers another test left held.
		local caps_at, first_key, last_key = {}, nil, nil
		for index, event in ipairs(channel.emitted) do
			if event.code == KEY_CAPSLOCK and event.value == 1 then caps_at[#caps_at + 1] = index end
			if (event.code == 48 or event.code == 24) and event.value == 1 then
				first_key = first_key or index
				last_key = index
			end
		end
		helpers.assert_eq(#caps_at, 2, "one press to release the lock, one to restore it")
		helpers.assert_true(first_key and caps_at[1] < first_key,
			"the lock must be released before the first planned key")
		helpers.assert_true(last_key and caps_at[2] > last_key,
			"and pressed again after the last one, leaving the user's CapsLock as it was")
		package.loaded["adapters.xkb_capture"] = nil
	end)

	helpers.it("leaves CapsLock alone when it is not locked", function()
		local injector, channel = load(false)
		injector.inject(0, "Bo")
		helpers.assert_eq(caps_presses(channel), 0)
		package.loaded["adapters.xkb_capture"] = nil
	end)

end)
