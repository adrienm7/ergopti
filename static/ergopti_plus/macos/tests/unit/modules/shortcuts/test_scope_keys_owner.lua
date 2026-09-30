--- tests/unit/modules/shortcuts/test_scope_keys_owner.lua

--- Keeps generated scope recommendations within the real static binding registry.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcut_bindings_fixture")
local Manifest = require("infra.manifest_reader")

helpers.describe("shortcut scope declared native owners", function()
	helpers.it("selects only real bindings and leaves the tap-key dispatcher derived", function()
		Fixture.with_bindings(function(bindings)
			local registered, selected = {}, 0
			for _, row in ipairs(bindings.list_shortcuts()) do registered[row.id] = true end
			helpers.assert_eq(registered.layer_wheel, true)
			helpers.assert_eq(registered.tap_keys, true)
			for _, row in ipairs(Manifest.scope_operations("shortcuts", "recommended")) do
				if row.section == "shortcuts.keys" then
					selected = selected + 1
					helpers.assert_eq(registered[row.key], true, "no native binding owns " .. row.key)
					helpers.assert_true(row.key ~= "tap_keys", "tap dispatcher derives from assignments")
					helpers.assert_true(row.key ~= "layer_wheel", "the layer's wheel derives from layers.toml")
				end
			end
			helpers.assert_true(selected > 0)
		end)
	end)
end)
