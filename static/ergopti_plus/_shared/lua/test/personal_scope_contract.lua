--- _shared/lua/test/personal_scope_contract.lua

--- ==============================================================================
--- MODULE: Personal Scope Admission Corpus Contract
--- DESCRIPTION:
--- Replays literal independent binding decisions on both Lua drivers. Native
--- filesystem and registry ownership stay in each caller's behavioral tests.
--- ==============================================================================

local M = {}

--- Clones inputs to observe mutation on successful and refused requests alike.
--- @param value any
--- @return any
local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

--- Registers each independent admission and input-ownership expectation.
--- @param helpers table Native test registration and assertion owner.
--- @param policy table Shared production admission policy.
--- @param corpus table Independent literal corpus.
function M.run(helpers, policy, corpus)
	assert(type(corpus.vectors) == "table" and #corpus.vectors == 11, "personal admission corpus must contain eleven vectors")
	helpers.describe("personal file admission parity", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(personal-file-admission) " .. vector.name, function()
				local before_inventory, before_selected = clone(vector.inventory), clone(vector.selected)
				local admitted, reason = policy.admit(vector.inventory, vector.selected)
				if vector.refusal then
					helpers.assert_eq(admitted, nil)
					helpers.assert_eq(reason, vector.refusal)
				else
					helpers.assert_eq(admitted, vector.expected)
					helpers.assert_eq(reason, nil)
					helpers.assert_true(admitted.source ~= vector.selected.source)
					helpers.assert_true(admitted.source.components ~= vector.selected.source.components)
				end
				helpers.assert_eq(vector.inventory, before_inventory)
				helpers.assert_eq(vector.selected, before_selected)
			end)
		end
	end)
end

return M
