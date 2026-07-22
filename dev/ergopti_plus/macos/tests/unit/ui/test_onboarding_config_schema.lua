--- tests/unit/ui/test_onboarding_config_schema.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard — Config Schema (regression)
--- DESCRIPTION:
--- Locks down that the first-run wizard writes config.toml keys using the SAME
--- schema the macOS Preferences loader reads (ui/menu/preferences.lua KEY_MAP):
--- lowercase sections + clean ``enabled`` flags.
---
--- ROOT CAUSE ENCODED: the wizard used to write AHK-style keys — [Metrics]
--- metrics_enabled, [Gestures] Enabled, [Hotstrings] MagicKey, [Layout] Ergopti*,
--- [Script] Locale — that the macOS loader (which reads [metrics].enabled,
--- [gestures].enabled, [hotstrings].enabled/trigger_char) never consults. Result:
--- enabling metrics + gestures in the wizard had NO effect after the reload. If a
--- future edit reverts to the AHK keys, the assertions below fail.
--- ==============================================================================

local helpers = require("tests.helpers")

local Onboarding = helpers.load_with_stubs("ui.onboarding")

--- Finds an update entry by section + key.
local function find(updates, section, key)
	for _, u in ipairs(updates) do
		if u.section == section and u.key == key then return u end
	end
	return nil
end

helpers.describe("onboarding: config updates use the canonical HS schema", function()
	helpers.it("writes the keys the macOS Preferences loader actually reads", function()
		local u = Onboarding._build_config_updates({
			use_ergopti = true, use_metrics = true, use_gestures = true, magic_key = "★",
		})
		helpers.assert_true(find(u, "metrics", "enabled") ~= nil,   "must write [metrics].enabled")
		helpers.assert_true(find(u, "gestures", "enabled") ~= nil,  "must write [gestures].enabled")
		helpers.assert_true(find(u, "hotstrings", "enabled") ~= nil, "must write [hotstrings].enabled")
		local tc = find(u, "hotstrings", "trigger_char")
		helpers.assert_true(tc ~= nil, "must write [hotstrings].trigger_char")
		helpers.assert_eq(tc.value, "★")
	end)

	helpers.it("maps boolean answers to real Lua booleans (not quoted strings)", function()
		local u = Onboarding._build_config_updates({ use_metrics = true, use_gestures = false })
		-- Must be booleans, NOT the strings "true"/"false": a quoted "false" decodes
		-- to the truthy Lua string "false" and silently re-enables a declined feature.
		helpers.assert_eq(find(u, "metrics", "enabled").value, true)
		helpers.assert_eq(find(u, "gestures", "enabled").value, false)
		helpers.assert_eq(type(find(u, "gestures", "enabled").value), "boolean")
	end)

	helpers.it("never emits the old AHK-style keys the macOS loader ignores", function()
		local u = Onboarding._build_config_updates({ use_metrics = true, use_gestures = true })
		for _, up in ipairs(u) do
			helpers.assert_true(
				up.section ~= "Metrics" and up.section ~= "Gestures"
				and up.section ~= "Layout" and up.section ~= "Script",
				"no capitalized AHK sections (the macOS loader reads lowercase)")
			helpers.assert_true(
				up.key ~= "metrics_enabled" and up.key ~= "Enabled" and up.key ~= "MagicKey",
				"no AHK-style keys the macOS loader never reads")
		end
	end)
end)
