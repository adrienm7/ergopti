--- tests/unit/diagnostics/engine/field_check/test_tap_hold_thresholds.lua

--- ==============================================================================
--- MODULE: Field Check, Deployed Tap-Hold Thresholds
--- DESCRIPTION:
--- Pins diagnostics/engine/field_check/tap_hold_thresholds.lua: the managed tap manipulators
--- of a deployed configuration must carry the key's own delay or the global
--- one (PAR-15); the user's own rules and non-tap manipulators never count.
---
--- ROOT CAUSE ENCODED: the PAR-15 delay model was proven only on the generator's
--- output. A deploy that kept a stale per-key threshold, or a merge that
--- rewrote one, would make a key fire its hold at another delay than the
--- other drivers with every unit test green; only the deployed file shows it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("diagnostics.engine.field_check.report")
local Check = require("diagnostics.engine.field_check.tap_hold_thresholds")

local TAG = "ErgoptiPlus managed"

--- A manipulator tapping one key with the given parameters.
local function tap(key_code, parameters)
	return { type = "basic", from = { key_code = key_code }, to_if_alone = { { key_code = key_code } },
		parameters = parameters }
end

--- A configuration whose first profile holds these rules.
local function config(rules)
	return { profiles = { { complex_modifications = { rules = rules } } } }
end

local EXPECTED = {
	caps_lock = { id = "caps_lock", ms = 200 },
	right_command = { id = "right_command", ms = 320 },
}

--- Runs the check over facts and returns the step map.
local function run(facts)
	local report = Report.new_report("tap_hold_thresholds")
	local finished = false
	Check.tap_hold_thresholds({ tap_hold_threshold_facts = function() return facts end }, report,
		function() finished = true end)
	helpers.assert_true(finished, "the check must finish")
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

helpers.describe("field check: deployed tap-hold thresholds (PAR-15)", function()
	helpers.it("passes when every managed tap manipulator carries the expected delay", function()
		local steps = run({ enabled = true, tag = TAG, expected = EXPECTED, config = config({
			{ description = "[" .. TAG .. ":abc:tap] Caps Lock Key", manipulators = {
				tap("caps_lock", { ["basic.to_if_alone_timeout_milliseconds"] = 200,
					["basic.to_if_held_down_threshold_milliseconds"] = 200 }),
				{ type = "basic", from = { key_code = "caps_lock" }, to = { { key_code = "caps_lock" } } },
			} },
			{ description = "[" .. TAG .. ":abc:tap] Right Command Key", manipulators = {
				tap("right_command", { ["basic.to_if_alone_timeout_milliseconds"] = 320 }),
			} },
			{ description = "My own rule", manipulators = { tap("caps_lock", { ["basic.to_if_alone_timeout_milliseconds"] = 999 }) } },
		}) })
		helpers.assert_eq(steps.thresholds_config.state, Report.STATE_PASS)
		helpers.assert_eq(steps.thresholds_checked.value, "2")
		helpers.assert_eq(steps.thresholds_match.state, Report.STATE_PASS)
	end)

	helpers.it("names a key whose deployed delay or held-down threshold differs", function()
		local steps = run({ enabled = true, tag = TAG, expected = EXPECTED, config = config({
			{ description = "[" .. TAG .. ":abc:tap] Caps Lock Key", manipulators = {
				tap("caps_lock", { ["basic.to_if_alone_timeout_milliseconds"] = 350 }),
			} },
		}) })
		helpers.assert_eq(steps.thresholds_match.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.thresholds_match.value, "mismatch_1:caps_lock:350_not_200")
		local held = Check.compare(config({
			{ description = "[" .. TAG .. ":abc:tap] x", manipulators = {
				tap("caps_lock", { ["basic.to_if_alone_timeout_milliseconds"] = 200,
					["basic.to_if_held_down_threshold_milliseconds"] = 250 }),
			} },
		}), EXPECTED, TAG)
		helpers.assert_eq(#held.mismatches, 1, "a held-down threshold of another value is a mismatch")
		local missing = Check.compare(config({
			{ description = "[" .. TAG .. ":abc:tap] x", manipulators = { tap("caps_lock", nil) } },
		}), EXPECTED, TAG)
		helpers.assert_eq(#missing.mismatches, 1, "a manipulator without its delay is a mismatch")
	end)

	helpers.it("skips by name when Karabiner is off or nothing managed taps", function()
		helpers.assert_eq(run({ enabled = false }).thresholds_config.value, "integration_off")
		helpers.assert_eq(run({ enabled = true, reason = "not_json" }).thresholds_config.value, "not_json")
		local none = run({ enabled = true, tag = TAG, expected = EXPECTED, config = config({}) })
		helpers.assert_eq(none.thresholds_match.state, Report.STATE_SKIP)
		helpers.assert_eq(none.thresholds_match.value, "no_managed_tap_hold")
	end)

	-- Field report 2026-11-06: the owned runtime was not installed, so no
	-- configuration existed and the thresholds failed as "unreadable" on top of
	-- the owned_* steps that already named the cause.
	helpers.it("skips while the owned runtime is not ready and fails a ready runtime with no file", function()
		local waiting = run({ enabled = true, reason = "owned_runtime_not_ready" }).thresholds_config
		helpers.assert_eq(waiting.state, Report.STATE_SKIP)
		helpers.assert_eq(waiting.value, "owned_runtime_not_ready")
		local missing = run({ enabled = true, reason = "not_deployed" }).thresholds_config
		helpers.assert_eq(missing.state, Report.STATE_FAIL)
		helpers.assert_eq(missing.value, "not_deployed")
	end)

	helpers.it("is registered as a field check with a field run step", function()
		helpers.assert_eq(require("diagnostics.engine.field_check.checks").checks.tap_hold_thresholds, Check.tap_hold_thresholds)
	end)
end)
