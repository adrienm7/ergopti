--- tests/unit/modules/shortcuts/keyboard/test_keyboard_geometry_dispatch.lua

--- ==============================================================================
--- MODULE: Physical Keyboard Geometry Dispatch Regression
--- DESCRIPTION:
--- Alternating raw ISO and ANSI virtual events must address one physical key.
--- The former alias union swallowed the extra ISO key and remapped both keys.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local function with_geometry(callback)
	helpers.with_stub_scope({ "platform.input.keyboard_geometry", "modules.shortcuts.tap_keys" }, function()
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
		local geometry = require("platform.input.keyboard_geometry")
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

	helpers.it("the left-of-one action follows the deployed Karabiner virtual keyboard (issue #95)", function()
		with_geometry(function(geometry)
			local deployed = "iso"
			geometry.set_virtual_form_source(function() return deployed end)
			local TapKeys = require("modules.shortcuts.tap_keys")
			helpers.assert_true(TapKeys.apply_configuration({ shortcuts = { tap_keys = {
				number_row_left = "screen_capture",
			} } }, function(id) return id == "screen_capture" end))
			-- Whatever model the virtual keyboard's events carry, an ISO virtual
			-- keyboard delivers the key left of 1 as 10 and the extra key as 50.
			for _, form in ipairs({ { "iso", 10, 50 }, { "ansi", 50, 10 } }) do
				deployed = form[1]
				for _, model in ipairs({ 40, 41, 43 }) do
					helpers.assert_eq(TapKeys.decide(form[2], model), "screen_capture",
						form[1] .. " virtual keyboard, model " .. model .. ": key left of 1")
					helpers.assert_nil(TapKeys.decide(form[3], model),
						form[1] .. " virtual keyboard, model " .. model .. ": extra ISO key")
				end
			end
			deployed = nil
			helpers.assert_eq(TapKeys.decide(10, 41), "screen_capture", "bare ISO keyboard")
			helpers.assert_eq(TapKeys.decide(50, 40), "screen_capture", "bare ANSI keyboard")
			helpers.assert_nil(TapKeys.decide(50, 41), "bare ISO keyboard: extra key")
		end)
	end)
end)
