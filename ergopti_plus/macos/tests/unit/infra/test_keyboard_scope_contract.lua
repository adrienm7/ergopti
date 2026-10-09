--- tests/unit/infra/test_keyboard_scope_contract.lua

--- Dynamic keyboard leaves have typed neutral values without inventing assignments.
local helpers = require("tests.helpers")
local Manifest = require("infra.manifest_reader")

helpers.describe("dynamic keyboard scope contract", function()
	helpers.it("makes an explicitly inventoried non-static keyboard assignment sparse", function()
		local path = "shortcuts.keyboard.hs_option_z"
		helpers.assert_nil(Manifest.find_entry_by_path(path))
		helpers.assert_eq(Manifest.default_for(path), "none")
		helpers.assert_eq(Manifest.sparse_operation(path, "none").delete, true)
		helpers.assert_eq(Manifest.sparse_operation(path, "send_text").value, "send_text")
		for _, mode in ipairs({ "clear", "recommended" }) do
			local inventory = Manifest.scope_inventory("shortcuts", { keyboard = function() return { path } end })
			local found = false
			for _, row in ipairs(Manifest.scope_plan("shortcuts", mode, inventory).operations) do
				if row.section == "shortcuts.keyboard" and row.key == "hs_option_z" then
					found = true; helpers.assert_eq(row.delete, true)
				end
			end
			helpers.assert_eq(found, true)
		end
	end)
	helpers.it("preserves string metadata and refuses unsupported dynamic shapes", function()
		local found = false
		for _, definition in ipairs(Manifest.scopes().shortcuts.dynamic_defaults) do
			if definition.prefix == "shortcuts.keyboard" then
				found = true; helpers.assert_eq(definition.type, "string")
			end
		end
		helpers.assert_eq(found, true)
		for _, path in ipairs({ "shortcuts.keyboard", "shortcuts.keyboard..x", "shortcuts.keyboard.x.child", "shortcuts.unowned.x" }) do
			local failure = helpers.assert_throws(function() Manifest.default_for(path) end, path)
			helpers.assert_contains(failure, "unknown configuration path: " .. path)
		end
	end)
end)
