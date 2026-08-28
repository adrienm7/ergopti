--- tests/unit/ui/test_onboarding_config_roundtrip.lua

--- ==============================================================================
--- MODULE: Onboarding config precedence regression tests
--- DESCRIPTION:
--- Executes the production answer decoder. Canonical macOS values must win even
--- when false; Windows migration keys are consulted only when canonical keys are
--- absent.
--- ==============================================================================

local helpers = require("tests.helpers")

local Onboarding = helpers.load_with_stubs("ui.onboarding")

local function conflicting_config(canonical_value)
	return {
		hotstrings = { enabled = canonical_value, trigger_char = "canonical" },
		metrics = { enabled = canonical_value },
		gestures = { enabled = canonical_value },
		Layout = {
			ErgoptiBase = true,
			ErgoptiAltGr = true,
			ErgoptiPlus = true,
		},
		Hotstrings = { MagicKey = "legacy" },
		Metrics = { metrics_enabled = true },
		Gestures = { Enabled = true },
	}
end

helpers.describe("Onboarding existing-config precedence", function()
	for _, case in ipairs({
		{ label = "boolean false", value = false },
		{ label = "string false", value = "false" },
	}) do
		helpers.it("keeps canonical " .. case.label .. " over enabled legacy keys", function()
			local answers = Onboarding._answers_from_config(conflicting_config(case.value))
			helpers.assert_eq(answers.use_ergopti, false,
				"a declined canonical hotstring setting must not fall through to Layout")
			helpers.assert_eq(answers.use_metrics, false,
				"a declined canonical metrics setting must not fall through to Metrics")
			helpers.assert_eq(answers.use_gestures, false,
				"a declined canonical gestures setting must not fall through to Gestures")
			helpers.assert_eq(answers.magic_key, "canonical",
				"a canonical trigger must remain authoritative")
		end)
	end

	helpers.it("uses legacy Windows values only when canonical keys are absent", function()
		local answers = Onboarding._answers_from_config({
			Layout = { ErgoptiBase = true },
			Hotstrings = { MagicKey = "legacy" },
			Metrics = { metrics_enabled = true },
			Gestures = { Enabled = true },
		})
		helpers.assert_true(answers.use_ergopti)
		helpers.assert_true(answers.use_metrics)
		helpers.assert_true(answers.use_gestures)
		helpers.assert_eq(answers.magic_key, "legacy")
	end)

	helpers.it("round-trips canonical enabled answers without legacy data", function()
		local answers = Onboarding._answers_from_config({
			hotstrings = { enabled = true, trigger_char = "canonical" },
			metrics = { enabled = "true" },
			gestures = { enabled = true },
		})
		helpers.assert_true(answers.use_ergopti)
		helpers.assert_true(answers.use_metrics)
		helpers.assert_true(answers.use_gestures)
		helpers.assert_eq(answers.magic_key, "canonical")
	end)
end)
