--- tests/unit/keyboard/engine/enable_transaction/test_setter_disk_commit.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("karabiner synchronous setters commit disk before live state", function()
	for _, mode in ipairs({ "disabled", "paused" }) do
		helpers.it("(live-tap-hold-transition) preserves intentional " .. mode .. " settings-only edits", function()
			with_fixture(function(fixture)
				local remap, calls = fixture.load_enabled_remap({
					initially_enabled = mode ~= "disabled", paused = mode == "paused",
				})
				package.loaded["keyboard.adapters.karabiner.lease_controller"].status = function()
					error("an intentional settings-only edit must not require a live lease")
				end
				helpers.assert_true(remap.set_hold_action("left_shift", "shift"))
				helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
				helpers.assert_eq(remap.get_hold_action("left_shift"), "shift")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(calls.save, 2)
				helpers.assert_eq(calls.saved_payloads[2].tap_hold_config.left_shift.hold, "shift")
				helpers.assert_eq(calls.saved_payloads[2].tap_hold_config.left_shift.tap, "escape")
				helpers.assert_eq(calls.build, 0)
				helpers.assert_eq(calls.deploy, 0)
				helpers.assert_eq(calls.stop, 0)
			end)
		end)
	end

	helpers.it("rolls back every setter class when persistence returns false", function()
		with_fixture(function(fixture)
			local remap = fixture.load_enabled_remap({ save_succeeds = false })
			local setters = {
				{ call = function() return remap.set_tap_action("left_shift", "escape") end,
					read = function() return remap.get_tap_action("left_shift") end, expected = "none" },
				{ call = function() return remap.set_hold_action("left_shift", "layer") end,
					read = function() return remap.get_hold_action("left_shift") end, expected = "none" },
				{ call = function() return remap.set_tap_timeout("left_shift", 321) end,
					read = function() return remap.get_tap_timeout("left_shift") end, expected = nil },
				{ call = function() return remap.set_combo_tap_action("left_shift+right_shift", "escape") end,
					read = function() return remap.get_combo_tap_action("left_shift+right_shift") end, expected = "none" },
				{ call = function() return remap.set_combo_hold_action("left_shift+right_shift", "layer") end,
					read = function() return remap.get_combo_hold_action("left_shift+right_shift") end, expected = "none" },
				{ call = function() return remap.set_combo_combo_action("left_shift+right_shift", "escape") end,
					read = function() return remap.get_combo_combo_action("left_shift+right_shift") end, expected = "none" },
				{ call = function() return remap.set_tap_hold_timeout(321) end,
					read = remap.get_tap_hold_timeout, expected = 200 },
				{ call = function() return remap.set_sticky_timeout(4321) end,
					read = remap.get_sticky_timeout, expected = 1000 },
				{ call = function() return remap.set_simultaneous_threshold(87) end,
					read = remap.get_simultaneous_threshold, expected = 50 },
				{ call = function() return remap.set_combo_symmetric(true) end,
					read = remap.get_combo_symmetric, expected = false },
			}
			for index, case in ipairs(setters) do
				helpers.assert_eq(case.call(), false, "setter " .. index .. " must expose save refusal")
				helpers.assert_eq(case.read(), case.expected,
					"setter " .. index .. " must preserve its pre-save live value")
			end
		end)
	end)

	helpers.it("refuses invalid timing values before persisting (remap-timing-invalid)", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local setters = {
				{ remap.set_sticky_timeout, remap.get_sticky_timeout },
				{ remap.set_tap_hold_timeout, remap.get_tap_hold_timeout },
				{ remap.set_simultaneous_threshold, remap.get_simultaneous_threshold },
			}
			for _, pair in ipairs(setters) do
				local original, before = pair[2](), calls.save
				for _, value in ipairs({ 0.5, 1.5, math.huge, -math.huge, 0/0, 2^54 }) do
					helpers.assert_eq(pair[1](value), false, "timeout must be a finite positive integer")
					helpers.assert_eq(pair[2](), original)
					helpers.assert_eq(calls.save, before, "invalid input must not reach persistence")
				end
			end
		end)
	end)

	helpers.it("does not clear a per-key override for malformed values (remap-timing-invalid)", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_timeout("left_shift", 321))
			local before = calls.save
			for _, value in ipairs({ "invalid", 0.5, 1.5, math.huge, -math.huge, 0/0, 2^54 }) do
				helpers.assert_eq(remap.set_tap_timeout("left_shift", value), false)
				helpers.assert_eq(remap.get_tap_timeout("left_shift"), 321)
				helpers.assert_eq(calls.save, before)
			end
			helpers.assert_true(remap.set_tap_timeout("left_shift", 0), "zero intentionally clears the override")
			helpers.assert_nil(remap.get_tap_timeout("left_shift"))
		end)
	end)

	helpers.it("reset publishes all defaults together or preserves every prior value", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			helpers.assert_true(remap.set_tap_action("left_shift", "escape"))
			helpers.assert_true(remap.set_combo_symmetric(true))
			helpers.assert_true(remap.set_tap_hold_timeout(321))
			calls.set_save_succeeds(false)

			helpers.assert_eq(remap.reset_to_defaults(), false)
			helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			helpers.assert_eq(remap.get_combo_symmetric(), true)
			helpers.assert_eq(remap.get_tap_hold_timeout(), 321)
		end)
	end)
end)
