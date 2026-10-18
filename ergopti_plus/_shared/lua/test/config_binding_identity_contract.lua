--- _shared/lua/test/config_binding_identity_contract.lua

--- ==============================================================================
--- MODULE: Configuration Binding Identity Contract
--- DESCRIPTION:
--- Replays the same publication and namespace decisions used by the native
--- gesture adapters. The corpus is shared with Windows, whose native owner
--- publishes prefixed identities rather than the Lua owners' bare slot ids.
--- ==============================================================================

local M = {}

--- Registers the shared publication and binding-identity vectors.
--- @param helpers table Native suite assertions.
--- @param corpus table Shared JSON vectors.
function M.register(helpers, corpus)
	local Identity = require("config_binding_identity")
	helpers.describe("shared published gesture binding identity", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it(vector.id, function()
				local catalogue
				if vector.expects_error then
					helpers.assert_throws(function() Identity.gesture_binding_fits(vector.binding, vector.catalogue) end)
					return
				end
				if vector.published ~= false then
					local slots = {}
					for _, slot in ipairs(vector.slots) do slots[slot] = true end
					catalogue = { prefix = vector.prefix, slots = slots }
				end
				local expected
				if vector.status == "current" then expected = true
				elseif vector.status == "retired" then expected = false end
				helpers.assert_eq(Identity.gesture_binding_fits(vector.binding, catalogue), expected, vector.id)
			end)
		end
		helpers.it("rejects malformed published catalogues as owner errors", function()
			helpers.assert_throws(function() Identity.gesture_binding_fits("tap_3", {}) end)
			helpers.assert_throws(function() Identity.gesture_binding_fits("tap_3", { prefix = "", slots = false }) end)
		end)
	end)
	helpers.describe("shared complete ordered-pair binding identity", function()
		helpers.it("combination-source-identity: projects all ordered native pairs without active assignments", function()
			local keys = { { id = "space" }, { id = "tab" }, { id = "win" } }
			local catalogue = Identity.combination_binding_catalogue(keys)
			helpers.assert_eq(catalogue, { prefix = "combination__", slots = {
				space_then_tab = true, space_then_win = true, tab_then_space = true,
				tab_then_win = true, win_then_space = true, win_then_tab = true,
			} })
			keys[1].id = "withdrawn"
			helpers.assert_eq(catalogue.slots.space_then_tab, true, "projection is detached")
			helpers.assert_eq(Identity.combination_binding_fits("combination__space_then_tab", catalogue), true)
			helpers.assert_eq(Identity.combination_binding_fits("combination__tab_then_space", catalogue), true)
			helpers.assert_eq(Identity.combination_binding_fits("combination__space_then_space", catalogue), false)
			helpers.assert_eq(Identity.combination_binding_fits("combination__removed_then_tab", catalogue), false)
			helpers.assert_nil(Identity.combination_binding_fits("keyboard__space_then_tab", catalogue))
			helpers.assert_nil(Identity.combination_binding_fits("combination__removed_then_tab", nil))
		end)
		for _, vector in ipairs({ { "empty", {} }, { "singleton", { { id = "space" } } },
			{ "duplicate", { { id = "space" }, { id = "space" } } },
			{ "sparse", { [1] = { id = "space" }, [3] = { id = "tab" } } },
			{ "qualified", { { id = "space__foreign" }, { id = "tab" } } } }) do
			local invalid = vector[2]
			helpers.it("combination-source-identity: refuses " .. vector[1] .. " ordered-pair key source", function()
				helpers.assert_throws(function() Identity.combination_binding_catalogue(invalid) end)
			end)
		end
	end)

end

return M
