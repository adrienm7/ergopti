--- tests/unit/hotstrings/engine/expander/registry/test_section_native_inverse.lua
--- A native inverse refusal retains the exact section owner for retry.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.hotstrings.registry_mutation_transactions_fixture")

helpers.describe("native section rollback ownership", function()
	helpers.it("retains the prior view on native refusal and rejects a replaced storage provider", function()
		local _, registry = Fixture.fresh_registry()
		registry.register_lua_group("owned", "Owned", { { name = "section" } })
		local storage = require("core.fs.adapters.storage")
		local key = registry.section_setting_key("owned", "section")
		helpers.assert_true(storage.set(key, false))
		local native_set, storage_set = hs.settings.set, storage.set
		local inverse_allowed, inverse_attempts = false, 0
		hs.settings.set = function(name, value)
			if name == "ergopti." .. key and value == false then
				inverse_attempts = inverse_attempts + 1
				if not inverse_allowed then return false end
			end
			return native_set(name, value)
		end
		local ok, err = xpcall(function()
			local changes = { { name = "owned", sections = { "section" } } }
			helpers.assert_eq(registry.set_groups_sections_enabled(changes, true, function() return false end), false)
			helpers.assert_true(inverse_attempts > 0, "the real native inverse was attempted")
			helpers.assert_eq(select(2, storage.read_exact(key)), true)
			helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
			storage.set = function() error("replacement provider must not be called") end
			inverse_allowed = true
			helpers.assert_eq(registry.migrate_legacy_section_settings(), false,
				"a changed provider cannot adopt the retained receipt")
			helpers.assert_eq(select(2, storage.read_exact(key)), true)
			storage.set = storage_set
			helpers.assert_true(registry.migrate_legacy_section_settings())
			helpers.assert_eq(select(2, storage.read_exact(key)), false)
			helpers.assert_eq(registry.is_section_enabled("owned", "section"), false)
		end, debug.traceback)
		hs.settings.set, storage.set = native_set, storage_set
		if not ok then error(err, 0) end
	end)
end)
