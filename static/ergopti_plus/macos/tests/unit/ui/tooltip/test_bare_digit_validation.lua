--- tests/unit/ui/tooltip/test_bare_digit_validation.lua

--- ==============================================================================
--- MODULE: Tooltip Bare-Digit Validation Regression
--- DESCRIPTION:
--- Drives the real LLM tooltip keyboard watcher with the exact shortcut string the
--- prediction engine renders for an empty validation chord. The engine encodes
--- `llm_val_modifiers = {}` as a zero-width space so the footer keeps its layout
--- slot; the watcher used to read that glyph as a required modifier, so a bare
--- digit dismissed the tooltip and reached the application instead of accepting
--- prediction N (tooltip-bare-digit-validation).
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_fixture = support.with_fixture
local CASES = support.CASES
local hardware_key_event = support.hardware_key_event
local drain_deferred_actions = support.drain_deferred_actions

-- Exact display form produced by format_validation_shortcut({}).
local EMPTY_CHORD_SHORTCUT = "\226\128\139"
local KEYCODE_DIGIT_2 = 19
local KEYCODE_DIGIT_4 = 21

--- Renders three predictions with the given validation shortcut and returns the
--- keyboard watcher plus the list of accepted indices.
--- @param fixture table Tooltip watcher fixture.
--- @param shortcut string Display-form validation shortcut.
--- @return table context, table key_watcher, table accepted
local function show_three(fixture, shortcut)
	local context = fixture.load_tooltip(CASES[1])
	local accepted = {}
	context.tooltip.set_accept_callback(function(index)
		accepted[#accepted + 1] = index
		return true
	end)
	helpers.assert_eq(context.tooltip.show_predictions(
		{ "one", "two", "three" }, 1, true, nil, shortcut, nil, nil, nil, nil, 3), true)
	return context, context.created[CASES[1].watcher_count], accepted
end

helpers.describe("tooltip_llm bare-digit validation chord", function()
	helpers.it("(tooltip-bare-digit-validation) a bare digit accepts prediction N and is consumed", function()
		with_fixture(function(fixture)
			local context, key_watcher, accepted = show_three(fixture, EMPTY_CHORD_SHORTCUT)
			helpers.assert_eq(key_watcher.fn(hardware_key_event(KEYCODE_DIGIT_2, {}, "2")), true,
				"a bare digit must be consumed while predictions are shown")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 2 },
				"a bare digit 2 must accept the second prediction")
		end)
	end)

	helpers.it("(tooltip-bare-digit-validation) a modified digit is not the empty chord", function()
		with_fixture(function(fixture)
			local context, key_watcher, accepted = show_three(fixture, EMPTY_CHORD_SHORTCUT)
			helpers.assert_eq(key_watcher.fn(hardware_key_event(KEYCODE_DIGIT_2, { alt = true }, "2")), false,
				"Alt+2 must reach the application when validation uses bare digits")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(#accepted, 0)
		end)
	end)

	helpers.it("(tooltip-bare-digit-validation) a configured modifier still owns the chord exactly", function()
		with_fixture(function(fixture)
			local context, key_watcher, accepted = show_three(fixture, "alt")
			helpers.assert_eq(key_watcher.fn(hardware_key_event(KEYCODE_DIGIT_2, { alt = true }, "2")), true,
				"Alt+2 must be consumed when validation requires Alt")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(accepted, { 2 })
		end)
		with_fixture(function(fixture)
			local context, key_watcher, accepted = show_three(fixture, "alt")
			helpers.assert_eq(key_watcher.fn(hardware_key_event(KEYCODE_DIGIT_2, {}, "2")), false,
				"a bare digit must type normally when validation requires Alt")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(#accepted, 0)
		end)
	end)

	helpers.it("(tooltip-bare-digit-validation) a digit beyond the shown pool passes through (HS-049)", function()
		with_fixture(function(fixture)
			local context, key_watcher, accepted = show_three(fixture, EMPTY_CHORD_SHORTCUT)
			helpers.assert_eq(key_watcher.fn(hardware_key_event(KEYCODE_DIGIT_4, {}, "4")), false,
				"digit 4 with three predictions keeps the documented pass-through")
			drain_deferred_actions(context.timers)
			helpers.assert_eq(#accepted, 0)
		end)
	end)
end)
