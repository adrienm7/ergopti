--- tests/unit/hotstrings/engine/expander/registry/test_section_capture_receipt.lua
--- An unchanged section still requires an authentic Storage capture receipt.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.keymap.registry.registry_mutation_transactions_fixture")

helpers.describe("section capture receipt admission", function()
	for _, kind in ipairs({ "nil", "false", "forged", "stale" }) do
		helpers.it("refuses a " .. kind .. " capture before publishing an unchanged cohort", function()
			local _, registry = Fixture.fresh_registry()
			registry.register_lua_group("owned", "Owned", { { name = "section" } })
			local storage = require("core.fs.adapters.storage")
			local key = registry.section_setting_key("owned", "section")
			helpers.assert_true(storage.set(key, true))
			local original = storage.capture_owned
			storage.capture_owned = function(owner)
				if kind == "stale" then
					local receipt, cells = original(owner)
					hs.settings.set("ergopti." .. key, false)
					return receipt, cells
				end
				local receipt
				if kind == "false" then receipt = false elseif kind == "forged" then receipt = {} end
				return receipt, { [key] = { present = true, value = kind ~= "forged" } }
			end
			local published = 0
			local accepted = registry.set_groups_sections_enabled({ { name = "owned", sections = { "section" } } }, true,
				function() published = published + 1; return true end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(published, 0, "no publication follows an unproved capture")
			if kind == "forged" then
				helpers.assert_eq(registry.is_section_enabled("owned", "section"), true,
					"quarantine must expose the previously observed state, not forged cells")
			end
			helpers.assert_eq(select(2, storage.read_exact(key)), kind ~= "stale")
			if kind ~= "forged" then
				helpers.assert_true(storage.set(key, false), "a refusal without a receipt releases the alias")
			else
				helpers.assert_eq(storage.set(key, false), false, "an unproved opaque receipt stays quarantined")
			end
			storage.capture_owned = original
		end)
	end
end)
