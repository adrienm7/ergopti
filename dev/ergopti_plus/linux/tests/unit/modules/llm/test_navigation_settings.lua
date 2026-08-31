--- tests/unit/modules/llm/test_navigation_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Validation Navigation
--- DESCRIPTION:
--- Proves durable modifier matching and lossless suppression of an accepted
--- digit through the real evdev dispatch path.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

helpers.describe("LLM navigation settings", function()
	helpers.it("reads the manifest default and matches the exact held chord", function()
		local previous = package.loaded["adapters.storage"]
		package.loaded["adapters.storage"] = Fakes.storage()
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_eq(settings.get(), { "alt" })
		helpers.assert_true(settings.matches({ alt = true }))
		helpers.assert_eq(settings.matches({ alt = true, shift = true }), false)
		package.loaded["adapters.storage"] = previous
	end)

	helpers.it("persists a canonical chord before publishing it", function()
		local previous = package.loaded["adapters.storage"]
		local storage = Fakes.storage()
		package.loaded["adapters.storage"] = storage
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_true(settings.set({ "shift", "ctrl" }))
		helpers.assert_eq(settings.get(), { "ctrl", "shift" })
		helpers.assert_eq(storage.get("llm.navigation.val_modifiers"), { "ctrl", "shift" })
		helpers.assert_eq(settings.set({ "alt", "alt" }), false)
		package.loaded["adapters.storage"] = previous
	end)
end)

helpers.describe("keyboard hook validation consumption", function()
	helpers.it("suppresses the accepted digit down, repeat, and release only in intercept mode", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local chars = {}
		local consumed = 0
		hook._test_drive({
			{ type = 1, code = 2, value = 1 },
			{ type = 1, code = 2, value = 2 },
			{ type = 1, code = 2, value = 0 },
			{ type = 1, code = 3, value = 1 },
		}, {
			onConsume = function(detail)
				if detail.key == "1" or detail.char == "1" then consumed = consumed + 1; return true end
				return false
			end,
			onChar = function(char) chars[#chars + 1] = char end,
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = string.format("%d:%d", code, value)
				return true
			end,
		}, true)
		helpers.assert_eq(consumed, 1, "autorepeat must remain owned by the accepted down event")
		helpers.assert_eq(emitted, { "3:1" })
		helpers.assert_eq(chars, { "2" })
	end)
end)
