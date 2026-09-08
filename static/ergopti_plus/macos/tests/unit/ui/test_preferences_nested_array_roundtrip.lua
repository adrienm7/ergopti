--- tests/unit/ui/test_preferences_nested_array_roundtrip.lua

--- ==============================================================================
--- MODULE: Nested Preference Array Roundtrip Regressions
--- DESCRIPTION:
--- Requires exact restoration of nested arrays and neighboring dictionaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.preferences_roundtrip_fixture")

local cases = {
	{ key = "llm_nav_modifiers", values = { "ctrl", "alt" } },
	{ key = "llm_disabled_apps", values = { "private.example", "second.example" } },
	{ key = "llm_user_models", values = {
		{ backend = "ollama", name = "first/model" },
		{ backend = "ollama", name = "second/model" },
	} },
	{ key = "llm_user_profiles", values = {
		{ id = "user_first", label = "First Profile", system_single = "first" },
		{ id = "user_second", label = "Second Profile", system_single = "second" },
	} },
}

--- Persists real TOML and checks the flat state returned to runtime consumers.
--- @param key string Flat preference key.
--- @param value table Expected array or dictionary.
local function check_roundtrip(key, value)
	fixture.with_roundtrip({ [key] = value }, function(saved, preferences)
		helpers.assert_eq(saved[key], value, key .. " must restore every value in order")
		local restored = { hotstrings = {} }
		preferences.merge_saved_data(restored, saved)
		helpers.assert_eq(restored[key], value, key .. " must reach runtime state unchanged")
	end)
end

helpers.describe("nested preference array restoration", function()
	for _, case in ipairs(cases) do
		for count = 0, #case.values do
			helpers.it("(nested-preference-array) restores " .. case.key .. " with " .. count .. " entries", function()
				local value = {}
				for index = 1, count do value[index] = case.values[index] end
				check_roundtrip(case.key, value)
			end)
		end
	end
	for key, value in pairs({
		llm_val_modifiers = { "ctrl", "alt" },
		llm_profile_shortcuts = { user_first = { mods = { "ctrl" }, key = "1" } },
		custom_editor_shortcut = { mods = { "alt" }, key = "e" },
	}) do
		helpers.it("(nested-preference-array) preserves neighboring value " .. key, function()
			check_roundtrip(key, value)
		end)
	end
end)
