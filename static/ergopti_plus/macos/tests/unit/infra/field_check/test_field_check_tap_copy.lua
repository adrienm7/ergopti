--- tests/unit/infra/field_check/test_field_check_tap_copy.lua

--- ==============================================================================
--- MODULE: Field Check, Tap-Hold Copy
--- DESCRIPTION:
--- Pins infra/field_check_tap_copy.lua: the field run reports the lone tap
--- window deployed for each copy key, the pasteboard counter, and what the
--- watched copy taps did, and fails on a copy that never landed
--- (tap-copy-field-check).
---
--- ROOT CAUSE ENCODED: a missed Shift copy on the maintainer's Mac left no line
--- in any report; only a real Mac shows whether the window, the counter and the
--- retry work, and the field report is the one channel back from it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("diagnostics.engine.field_check.report")
local Check = require("infra.field_check_tap_copy")
local TapCopy = require("modules.keymap.tap_copy")

--- Runs the check over facts and returns the step map.
local function run(facts)
	local report = Report.new_report("tap_copy")
	local finished = false
	Check.tap_copy({ tap_copy_facts = function() return facts end }, report, function() finished = true end)
	helpers.assert_true(finished, "the check must finish")
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

--- Statistics with these counts.
local function stats(fields)
	local value = TapCopy.empty_stats()
	for key, field in pairs(fields) do value[key] = field end
	return value
end

helpers.describe("field check: tap-hold copy (tap-copy-field-check)", function()
	helpers.it("reports the window, the counter and the session's copies (tap-copy-field-check)", function()
		local steps = run({ window_ms = 1000, change_count = 42,
			keys = { { id = "left_shift", deployed_ms = 1000, eligible = true } },
			stats = stats({ sent = 3, held_ms = { 120, 260, 310 }, missing_past = 1, missing_within = 2,
				missing_held_ms = { 1200, 90, 150 }, outcomes = { copied = 2, copied_on_retry = 1 } }) })
		helpers.assert_eq(steps.copy_watch.state, Report.STATE_PASS)
		helpers.assert_eq(steps.copy_window.state, Report.STATE_PASS)
		helpers.assert_eq(steps.copy_window.value, "w1000:left_shift:1000")
		helpers.assert_eq(steps.copy_counter.value, "42")
		helpers.assert_eq(steps.copies_sent.value, "3:held_120+260+310")
		helpers.assert_eq(steps.copies_verified.value, "2")
		helpers.assert_eq(steps.copies_on_retry.value, "1")
		helpers.assert_eq(steps.taps_without_copy.value, "past_1:within_2:held_1200+90+150")
		helpers.assert_eq(steps.copies_lost.state, Report.STATE_PASS)
	end)

	helpers.it("fails a copy that never landed and a window that was not deployed (tap-copy-field-check)", function()
		local steps = run({ window_ms = 1000, change_count = 1,
			keys = { { id = "left_shift", deployed_ms = 200, eligible = true } },
			stats = stats({ sent = 1, outcomes = { not_copied = 1 } }) })
		helpers.assert_eq(steps.copy_window.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.copy_window.value, "short:w1000:left_shift:200")
		helpers.assert_eq(steps.copies_lost.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.copies_lost.value, "1")
	end)

	helpers.it("names a stopped keymap, no copy key and an unreadable counter (tap-copy-field-check)", function()
		helpers.assert_eq(run({ keys = {} }).copy_watch.value, "keymap_not_started")
		local steps = run({ window_ms = 0, keys = {}, stats = stats({}) })
		helpers.assert_eq(steps.copy_window.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.copy_window.value, "no_copy_tap")
		helpers.assert_eq(steps.copy_counter.value, "unreadable")
		local strict = run({ window_ms = 0, change_count = 3,
			keys = { { id = "left_shift", deployed_ms = 200, eligible = true } }, stats = stats({}) })
		helpers.assert_eq(strict.copy_window.state, Report.STATE_PASS, "with the window off the delay is right")
	end)

	-- Field report 2026-11-06: with the owned runtime not installed, nothing was
	-- generated and the window failed as "short:w1000:left_shift:nil".
	helpers.it("skips the window when no configuration was generated this session (tap-copy-field-check)", function()
		local steps = run({ window_ms = 1000, change_count = 1, deployed = false,
			keys = { { id = "left_shift", eligible = true } }, stats = stats({}) })
		helpers.assert_eq(steps.copy_window.state, Report.STATE_SKIP)
		helpers.assert_eq(steps.copy_window.value, "not_deployed")
		local generated = run({ window_ms = 1000, change_count = 1, deployed = true,
			keys = { { id = "left_shift", eligible = true } }, stats = stats({}) })
		helpers.assert_eq(generated.copy_window.state, Report.STATE_FAIL, "a generated config without the key's delay fails")
	end)

	helpers.it("is registered as a field check with a field run step (tap-copy-field-check)", function()
		helpers.assert_eq(require("infra.field_check_checks").checks.tap_copy, Check.tap_copy)
	end)
end)
