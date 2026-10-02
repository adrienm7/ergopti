--- _shared/lua/hotstrings/bulk_scope.lua

--- ==============================================================================
--- MODULE: Hotstring Category Bulk Selection (Shared)
--- DESCRIPTION:
--- Plans explicit category and section choices for scoped enable/disable
--- commands. Native owners commit the complete plan; independent engine gates
--- and categories outside the selected scope are never part of it.
--- ==============================================================================

local M = {}


--- Whether a value can identify one separately addressable configuration leaf.
--- @param value any
--- @return boolean
local function addressable(value)
	return type(value) == "string" and value ~= "" and not value:find(".", 1, true)
end


--- Whether a table is a dense array, including the empty array.
--- @param values any
--- @return boolean
local function dense(values)
	if type(values) ~= "table" then return false end
	local count = 0
	for key in pairs(values) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #values then return false end
		count = count + 1
	end
	return count == #values
end


--- Plans all choices before an owner touches persistence or runtime.
--- @param inventory table Map of category id to actionable section names.
--- @param targets table Dense array of selected category ids.
--- @param enabled boolean Explicit target; never inferred from mixed state.
--- @return table|nil changes Dense `{ group, section|nil, enabled }` records.
--- @return string|nil reason Stable refusal identifier, without user values.
function M.plan(inventory, targets, enabled)
	if type(inventory) ~= "table" or not dense(targets) or type(enabled) ~= "boolean" then
		return nil, "invalid-request"
	end
	if #targets == 0 then return nil, "empty-scope" end
	local changes, selected = {}, {}
	for _, id in ipairs(targets) do
		if not addressable(id) or selected[id] then return nil, "invalid-category" end
		if not dense(inventory[id]) then return nil, "unknown-category" end
		selected[id] = true
		changes[#changes + 1] = { group = id, enabled = enabled }
		local sections = {}
		for _, name in ipairs(inventory[id]) do
			if not addressable(name) or name == "-" or sections[name] then return nil, "invalid-section" end
			sections[name] = true
			-- The legacy remapping lives in Layout, outside Hotstrings controls.
			if not (id:gsub("_", ""):lower() == "magickey" and name == "replace") then
				changes[#changes + 1] = { group = id, section = name, enabled = enabled }
			end
		end
	end
	return changes
end

return M
