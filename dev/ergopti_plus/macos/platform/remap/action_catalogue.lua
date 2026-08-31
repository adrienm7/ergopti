--- platform/remap/action_catalogue.lua

--- ==============================================================================
--- MODULE: Karabiner Action Catalogue Validation
--- DESCRIPTION:
--- Owns the action-id namespace shared by file-backed and generated actions.
--- Every consumer indexes through this module so duplicate ids fail closed.
--- ==============================================================================

local M = {}

--- Builds an action-id index after validating the complete catalogue shape.
--- @param actions table Dense array of action definitions.
--- @return table|nil index Unique id-to-action lookup.
--- @return string|nil error_message Validation failure.
function M.index_by_id(actions)
	if type(actions) ~= "table" then return nil, "action catalogue must be a dense array" end

	local length = #actions
	local count = 0
	for key in pairs(actions) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return nil, "action catalogue must be a dense array"
		end
		count = count + 1
	end
	if count ~= length then return nil, "action catalogue must be a dense array" end

	local index = {}
	for position, action in ipairs(actions) do
		if type(action) ~= "table" then
			return nil, string.format("action catalogue item %d must be a table", position)
		end
		local id = action.id
		if type(id) ~= "string" or id == "" then
			return nil, string.format("action catalogue item %d lacks a non-empty id", position)
		end
		if index[id] then
			return nil, string.format("action catalogue has duplicate id '%s'", id)
		end
		index[id] = action
	end
	return index
end

return M
