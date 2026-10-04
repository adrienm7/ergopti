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
--- @param bound_sections table|nil Dense `{ group, section }` leaves supplied by an extension.
--- @return table|nil changes Dense `{ group, section|nil, enabled }` records.
--- @return string|nil reason Stable refusal identifier, without user values.
function M.plan(inventory, targets, enabled, bound_sections)
	if bound_sections == nil then bound_sections = {} end
	if type(inventory) ~= "table" or not dense(targets) or not dense(bound_sections)
		or type(enabled) ~= "boolean" then
		return nil, "invalid-request"
	end
	if #targets == 0 and #bound_sections == 0 then return nil, "empty-scope" end
	local changes, selected, leaves = {}, {}, {}
	for _, id in ipairs(targets) do
		if not addressable(id) or selected[id] then return nil, "invalid-category" end
		if not dense(inventory[id]) then return nil, "unknown-category" end
		selected[id] = true
		changes[#changes + 1] = { group = id, enabled = enabled }
		local sections = {}
		for _, name in ipairs(inventory[id]) do
			if not addressable(name) or name == "-" or sections[name] then return nil, "invalid-section" end
			sections[name] = true
			changes[#changes + 1] = { group = id, section = name, enabled = enabled }
			leaves[id .. "\0" .. name] = true
		end
	end
	local bound_seen = {}
	for _, leaf in ipairs(bound_sections) do
		if type(leaf) ~= "table" or not addressable(leaf.group) or not addressable(leaf.section)
			or leaf.section == "-" then return nil, "invalid-section" end
		if not dense(inventory[leaf.group]) then return nil, "unknown-category" end
		local found, names = false, {}
		for _, name in ipairs(inventory[leaf.group]) do
			if not addressable(name) or name == "-" or names[name] then return nil, "invalid-section" end
			names[name] = true
			if name == leaf.section then found = true end
		end
		local key = leaf.group .. "\0" .. leaf.section
		if not found or bound_seen[key] then return nil, "invalid-section" end
		bound_seen[key] = true
		-- Opening a bound section needs its category gate. Closing it never closes
		-- that category: an extension does not own its unrelated symbol sections.
		if enabled and not selected[leaf.group] then
			changes[#changes + 1] = { group = leaf.group, enabled = true }
			selected[leaf.group] = true
		end
		if not leaves[key] then
			changes[#changes + 1] = { group = leaf.group, section = leaf.section, enabled = enabled }
			leaves[key] = true
		end
	end
	return changes
end

return M
