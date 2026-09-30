--- tests/unit/modules/llm/test_navigation_settings.lua

--- ==============================================================================
--- MODULE: Linux LLM Validation Navigation
--- DESCRIPTION:
--- Proves durable modifier matching and lossless suppression of an accepted
--- digit through the real evdev dispatch path.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

helpers.describe("LLM navigation settings", function()
	helpers.it("reads the manifest default and matches the exact held chord", function()
		local previous = package.loaded["infra.llm_preferences"]
		package.loaded["infra.llm_preferences"] = PreferencesFixture.new()
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_eq(settings.get(), {}, "a bare digit accepts by default")
		helpers.assert_true(settings.matches({}))
		helpers.assert_eq(settings.matches({ alt = true }), false, "Alt+1 is not the default chord")
		helpers.assert_eq(settings.matches({ shift = true }), false, "Shift+1 is a character")
		helpers.assert_true(settings.set({ "alt" }))
		helpers.assert_true(settings.matches({ alt = true }), "the menu can require Alt")
		helpers.assert_eq(settings.matches({}), false, "and then a bare digit types")
		package.loaded["infra.llm_preferences"] = previous
	end)

	helpers.it("persists a canonical chord before publishing it", function()
		local previous = package.loaded["infra.llm_preferences"]
		local storage = PreferencesFixture.new()
		package.loaded["infra.llm_preferences"] = storage
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_true(settings.set({ "shift", "ctrl" }))
		helpers.assert_eq(settings.get(), { "ctrl", "shift" })
		helpers.assert_eq(storage.get("llm.navigation.val_modifiers"), { "ctrl", "shift" })
		helpers.assert_eq(settings.set({ "alt", "alt" }), false)
		package.loaded["infra.llm_preferences"] = previous
	end)

	helpers.it("keeps a navigation chord of its own, bare by default (llm-tooltip-chords-consumed)", function()
		local previous = package.loaded["infra.llm_preferences"]
		local storage = PreferencesFixture.new()
		package.loaded["infra.llm_preferences"] = storage
		local settings = helpers.load_module("modules.llm.navigation_settings")
		settings._reset()
		helpers.assert_eq(settings.get_navigation(), {}, "bare Up and Down navigate by default")
		helpers.assert_true(settings.matches_navigation({}))
		helpers.assert_eq(settings.matches_navigation({ shift = true }), false, "Shift+Down is the application's")
		helpers.assert_true(settings.set_navigation({ "shift", "ctrl" }))
		helpers.assert_eq(settings.get_navigation(), { "ctrl", "shift" })
		helpers.assert_eq(storage.get("llm.navigation.nav_modifiers"), { "ctrl", "shift" })
		helpers.assert_eq(settings.get(), {}, "the validation chord is a separate setting")
		helpers.assert_true(settings.matches_navigation({ ctrl = true, shift = true }))
		helpers.assert_eq(settings.matches_navigation({ ctrl = true, shift = true, alt = true }), false)
		helpers.assert_eq(settings.set_navigation({ "win" }), false, "only the four chord modifiers exist")
		package.loaded["infra.llm_preferences"] = previous
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
