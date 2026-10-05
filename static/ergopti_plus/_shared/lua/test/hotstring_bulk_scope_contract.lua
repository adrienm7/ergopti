--- _shared/lua/test/hotstring_bulk_scope_contract.lua

--- ==============================================================================
--- MODULE: Hotstring Category Selection Corpus Contract
--- DESCRIPTION:
--- The Lua drivers replay the same independent expected batches and refusals
--- as Windows. Every selected category and section has an explicit Boolean;
--- another category and the engine master are excluded. The native replacement
--- choice belongs to its extension's Hotstrings section and participates there.
--- ==============================================================================

local M = {}


--- Copies corpus inputs so mutation is detected even on a rejected request.
--- @param value any
--- @return any
local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end


--- Registers actual planner replays against the shared golden corpus.
--- @param helpers table Driver assertion and registration API.
--- @param planner table Shared selection policy.
--- @param corpus table Decoded vectors; loading errors must propagate.
function M.run(helpers, planner, corpus)
	assert(type(corpus.vectors) == "table" and #corpus.vectors > 0, "the selection corpus must contain cases")
	helpers.describe("hotstring category selection parity", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(hotstring-category-scope) " .. vector.name, function()
				local inventory, targets = clone(vector.inventory), clone(vector.targets)
				local changes, reason = planner.plan(vector.inventory, vector.targets, vector.enabled)
				if vector.refusal then
					helpers.assert_eq(changes, nil, "a refused scope cannot emit a partial batch")
					helpers.assert_eq(reason, vector.refusal)
				else
					helpers.assert_eq(changes, vector.expected)
					helpers.assert_eq(reason, nil)
				end
				helpers.assert_eq(vector.inventory, inventory, "discovered catalogue is retained")
				helpers.assert_eq(vector.targets, targets, "the caller's selected scope is retained")
			end)
		end
	end)
end

return M
