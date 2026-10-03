--- _shared/lua/shortcuts/assignment.lua

--- Keeps explicit ordinary keyboard assignments distinct from neutral absence.
--- Scope clear/restoration and fresh templates retain their sparse semantics.
local M = {}

M.INTENT = "keyboard_assignment"

--- Builds one user assignment after the actual host validates both catalogues.
--- @param slot_id string Stable ordinary owned slot, contextual slots included.
--- @param action_id string Assignable action, including explicit "none".
--- @param is_owned function Exact native ordinary-slot catalogue predicate.
--- @param is_assignable function Exact native assignable-action predicate.
--- @return table operation Nondelete row for the existing acknowledged writer.
function M.operation(slot_id, action_id, is_owned, is_assignable)
	assert(type(slot_id) == "string" and slot_id ~= "" and type(action_id) == "string"
		and type(is_owned) == "function" and type(is_assignable) == "function",
		"keyboard assignment requires its actual slot and action owners")
	assert(is_owned(slot_id) == true, "keyboard assignment slot is not owned")
	assert(is_assignable(action_id) == true, "keyboard assignment action is not assignable")
	return { section = "shortcuts.keyboard", key = slot_id, value = action_id, intent = M.INTENT }
end

--- Recognizes only the closed keyboard assignment intent at the writer boundary.
--- @param row table Writer operation before neutral projection.
--- @return boolean intentional Whether sparse normalization must preserve value.
function M.is_intentional(row)
	if row.intent == nil then return false end
	assert(row.intent == M.INTENT and row.section == "shortcuts.keyboard"
		and type(row.key) == "string" and row.key ~= ""
		and row.delete == nil and type(row.value) == "string",
		"keyboard assignment intent requires an exact nondelete ordinary action row")
	return true
end

return M
