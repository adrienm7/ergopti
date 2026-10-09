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
end

return M
