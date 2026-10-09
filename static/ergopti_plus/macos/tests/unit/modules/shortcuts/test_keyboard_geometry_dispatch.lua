--- tests/unit/modules/shortcuts/test_keyboard_geometry_dispatch.lua

--- ==============================================================================
--- MODULE: Physical Keyboard Geometry Dispatch Regression
--- DESCRIPTION:
--- Alternating raw ISO and ANSI virtual events must address one physical key.
--- The former alias union swallowed the extra ISO key and remapped both keys.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function with_geometry(callback)
	helpers.with_stub_scope({ "adapters.keyboard_geometry", "modules.shortcuts.tap_keys",
		"modules.keymap.magic_key_source" }, function()
		local getenv = os.getenv
		os.getenv = function(key)
			if key ~= "ERGOPTI_KEYBOARD_GEOMETRY_V1" then return getenv(key) end
			return Json.encode({ version = 1, maximum = 32767, ranges = {
				{ first = 0, last = 40, form = "ansi" },
				{ first = 41, last = 41, form = "iso" },
				{ first = 42, last = 42, form = "jis" },
				{ first = 43, last = 32767, form = "unknown" },
			} })
		end
		local geometry = require("adapters.keyboard_geometry")
		local called, initialized = pcall(geometry.initialize)
		os.getenv = getenv
		helpers.assert_true(called and initialized, tostring(initialized))
		callback(geometry)
	end)
end

helpers.describe("per-event physical keyboard geometry (ansi-iso-position)", function()
	helpers.it("the left-of-one action leaves the extra ISO key alone on mixed keyboards", function()
		with_geometry(function()
			local TapKeys = require("modules.shortcuts.tap_keys")
			helpers.assert_true(TapKeys.apply_configuration({ shortcuts = { tap_keys = {
				number_row_left = "screen_capture",
			} } }, function(id) return id == "screen_capture" end))
			for _, case in ipairs({
				{ 41, 50, false }, { 41, 10, true }, { 40, 10, false },
				{ 40, 50, true }, { 41, 10, true }, { 40, 50, true },
				{ 43, 10, false }, { 43, 50, false }, { 42, 50, false },
			}) do
				local action = TapKeys.decide(case[2], case[1])
				helpers.assert_eq(action == "screen_capture", case[3],
					"keyboard model " .. case[1] .. ", virtual code " .. case[2])
			end
			helpers.assert_nil(TapKeys.decide(50), "missing geometry must not claim a physical position")
		end)
	end)

	helpers.it("Backquote and IntlBackslash remap only their own physical key", function()
		with_geometry(function()
			local Source = require("modules.keymap.magic_key_source")
			local on = function() return true end
			for _, case in ipairs({
				{ "Backquote", 41, 50, false }, { "Backquote", 41, 10, true },
				{ "Backquote", 40, 50, true }, { "Backquote", 40, 10, false },
				{ "IntlBackslash", 41, 10, false }, { "IntlBackslash", 41, 50, true },
				{ "IntlBackslash", 40, 10, true }, { "IntlBackslash", 40, 50, false },
			}) do
				Source.set(case[1])
				helpers.assert_eq(Source.remaps(case[3], {}, on, case[2]), case[4],
					case[1] .. ", keyboard model " .. case[2] .. ", virtual code " .. case[3])
			end
			Source.set("Backquote")
			helpers.assert_eq(Source.remaps(50, {}, on), false, "missing geometry")
			Source.set("KeyJ")
			helpers.assert_true(Source.remaps(38, {}, on), "unambiguous keys need no geometry")
		end)
	end)
end)
