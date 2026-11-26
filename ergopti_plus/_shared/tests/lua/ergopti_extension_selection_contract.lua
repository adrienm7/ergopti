--- _shared/tests/lua/ergopti_extension_selection_contract.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Selection Contract
--- DESCRIPTION:
--- Independent exact operation batches for whole packs and native bound leaves.
--- A module marker is never actionable: no catalogue section is a native feature.
--- ==============================================================================

local M = {}

--- Registers the same policy cases in both Lua native suites.
--- @param helpers table Native test assertions.
function M.run(helpers)
	local Scope = require("hotstrings.engine.bulk_scope")
	local Languages = require("hotstrings.engine.languages")
	helpers.describe("Ergopti extension selection policy", function()
		helpers.it("(ergopti-extension-selection) enables exact bound leaves and opens their category once", function()
			local inventory = { rolls = { "hc" }, magickey = { "repeat_corrections", "symbols" } }
			local bindings = { { group = "magickey", section = "repeat_corrections" } }
			local plan = Scope.plan(inventory, { "rolls" }, true, bindings)
			helpers.assert_eq(plan, {
				{ group = "rolls", enabled = true }, { group = "rolls", section = "hc", enabled = true },
				{ group = "magickey", enabled = true },
				{ group = "magickey", section = "repeat_corrections", enabled = true },
			})
			helpers.assert_eq(inventory.magickey, { "repeat_corrections", "symbols" })
			helpers.assert_eq(bindings[1], { group = "magickey", section = "repeat_corrections" })
		end)
		helpers.it("(ergopti-extension-selection) closes a bound feature without touching symbols or its category", function()
			helpers.assert_eq(Scope.plan({ magickey = { "repeat_corrections", "symbols" } }, {}, false,
				{ { group = "magickey", section = "repeat_corrections" } }), {
				{ group = "magickey", section = "repeat_corrections", enabled = false },
			})
		end)
		for _, request in ipairs({
			{ name = "missing category", bound = { { group = "missing", section = "repeat_corrections" } }, reason = "unknown-category" },
			{ name = "missing section", bound = { { group = "magickey", section = "missing" } }, reason = "invalid-section" },
			{ name = "duplicate bound section", bound = { { group = "magickey", section = "repeat_corrections" },
				{ group = "magickey", section = "repeat_corrections" } }, reason = "invalid-section" },
			{ name = "malformed bound scope", bound = false, reason = "invalid-request" },
		}) do
			helpers.it("(ergopti-extension-selection) refuses " .. request.name .. " before emitting any operation", function()
				local plan, reason = Scope.plan({ magickey = { "repeat_corrections" } }, {}, true, request.bound)
				helpers.assert_nil(plan)
				helpers.assert_eq(reason, request.reason)
			end)
		end
		helpers.it("(ergopti-extension-selection) a module marker is never an actionable section", function()
			helpers.assert_eq(Languages.section_actionable({ name = "replace", is_module_placeholder = true }), false)
			helpers.assert_eq(Languages.section_actionable({ name = "personal_info", is_module_placeholder = true }), false)
			helpers.assert_true(Languages.section_actionable({ name = "repeat_corrections" }))
			helpers.assert_eq(Languages.section_actionable({ name = "-" }), false)
		end)
	end)
end

return M
