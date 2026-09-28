--- tests/unit/infra/test_llm_scope_contract.lua

--- Proves the scope is backed by existing macOS preference owners.
local helpers = require("tests.helpers")
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")

helpers.describe("llm-scope-contract", function()
	helpers.it("resolves every declared scalar and table through the real preference owner", function()
		local found = {}
		for _, row in ipairs(Manifest.scope_operations("llm", "clear")) do
			local path = row.section .. "." .. row.key
			helpers.assert_not_nil(Preferences.flat_key_for(path), path)
			found[path] = true
		end
		for _, path in ipairs({ "llm.trigger.disabled_apps", "llm.navigation.nav_modifiers", "llm.models.user_models", "llm.profiles.user_profiles" }) do
			helpers.assert_true(found[path], path)
		end
		helpers.assert_nil(found["llm.user_profiles"])
		helpers.assert_nil(found["llm.profiles.auto_profile_for_model"])
	end)

	helpers.it("plans only supplied shortcut leaves and keeps restoration consent excluded", function()
		local paths = Manifest.scope_inventory("llm", { profiles = function()
			return { "llm.profiles.shortcuts.basic.mods", "llm.profiles.shortcuts.basic.key" }
		end })
		local found = {}
		for _, row in ipairs(Manifest.scope_operations("llm", "recommended", paths)) do
			found[row.section .. "." .. row.key] = row
		end
		helpers.assert_nil(found["llm.enabled"])
		helpers.assert_true(found[paths[1]].delete)
		helpers.assert_true(found[paths[2]].delete)
		helpers.assert_nil(found["llm.profiles.shortcuts.unknown.key"])
	end)
end)
