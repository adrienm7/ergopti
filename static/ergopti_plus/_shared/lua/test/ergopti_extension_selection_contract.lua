--- _shared/lua/test/ergopti_extension_selection_contract.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Selection Contract
--- DESCRIPTION:
--- Independent exact operation batches for whole packs and native bound leaves.
--- A native feature's empty metadata section is actionable; a module marker is not.
--- ==============================================================================

local M = {}

--- Registers the same policy cases in both Lua native suites.
--- @param helpers table Native test assertions.
--- @param features table Actual generated manifest feature declarations.
function M.run(helpers, features)
	local Scope = require("hotstrings.bulk_scope")
	local Languages = require("hotstrings.languages")
	helpers.describe("Ergopti extension selection policy", function()
		helpers.it("(ergopti-extension-selection) enables exact bound leaves and opens their category once", function()
			local inventory = { rolls = { "hc" }, magickey = { "replace", "repeat_corrections", "symbols" } }
			local bindings = { { group = "magickey", section = "replace" },
				{ group = "magickey", section = "repeat_corrections" } }
			local plan = Scope.plan(inventory, { "rolls" }, true, bindings)
			helpers.assert_eq(plan, {
				{ group = "rolls", enabled = true }, { group = "rolls", section = "hc", enabled = true },
				{ group = "magickey", enabled = true }, { group = "magickey", section = "replace", enabled = true },
				{ group = "magickey", section = "repeat_corrections", enabled = true },
			})
			helpers.assert_eq(inventory.magickey, { "replace", "repeat_corrections", "symbols" })
			helpers.assert_eq(bindings[1], { group = "magickey", section = "replace" })
		end)
		helpers.it("(ergopti-extension-selection) closes a bound feature without touching symbols or its category", function()
			helpers.assert_eq(Scope.plan({ magickey = { "replace", "symbols" } }, {}, false,
				{ { group = "magickey", section = "replace" } }), {
				{ group = "magickey", section = "replace", enabled = false },
			})
		end)
		for _, request in ipairs({
			{ name = "missing category", bound = { { group = "missing", section = "replace" } }, reason = "unknown-category" },
			{ name = "missing section", bound = { { group = "magickey", section = "missing" } }, reason = "invalid-section" },
			{ name = "duplicate bound section", bound = { { group = "magickey", section = "replace" },
				{ group = "magickey", section = "replace" } }, reason = "invalid-section" },
			{ name = "malformed bound scope", bound = false, reason = "invalid-request" },
		}) do
			helpers.it("(ergopti-extension-selection) refuses " .. request.name .. " before emitting any operation", function()
				local plan, reason = Scope.plan({ magickey = { "replace" } }, {}, true, request.bound)
				helpers.assert_nil(plan)
				helpers.assert_eq(reason, request.reason)
			end)
		end
		helpers.it("(ergopti-extension-selection) distinguishes the declared native feature from a declared module marker", function()
			helpers.assert_true(Languages.section_actionable(features, "magickey",
				{ name = "replace", is_module_placeholder = true }))
			local module_features = { { path = "hotstrings.dynamic.personal_info", type = "feature",
				section = "hotstrings.dynamic", id = "personal_info", default = { enabled = false } } }
			helpers.assert_eq(Languages.section_actionable(module_features, "dynamic",
				{ name = "personal_info", is_module_placeholder = true }), false)
			helpers.assert_eq(Languages.section_actionable({}, "magickey",
				{ name = "replace", is_module_placeholder = true }), false)
		end)
	end)
end

return M
