--- _shared/lua/config_user_models.lua

--- ==============================================================================
--- MODULE: Intrinsic Saved Model Records
--- DESCRIPTION:
--- Owns structural admission of saved model records, never provider inventory or
--- availability. Unknown custom names, backend identifiers and fields survive.
--- ==============================================================================

local M = {}
local Outdated = require("config_outdated")
local LeafRows = require("toml_codec.leaf_rows")
M.PATH = { "llm", "models", "user_models" }
M.REASON = "a saved model record needs nonempty plain string backend and name fields"

--- Judges only the fields the actual native saved-model selector consumes.
--- @param row any Parsed record.
--- @param shapes table|nil Actual decoder evidence, when reading source.
--- @return boolean fits
function M.fits(row, shapes)
	if type(row) ~= "table" or getmetatable(row) ~= nil then return false end
	local strings = shapes and shapes.strings and shapes.strings[row]
	for _, key in ipairs({ "backend", "name" }) do
		if type(rawget(row, key)) ~= "string" or rawget(row, key) == ""
			or strings and strings[key] ~= nil then return false end
	end
	return true
end

--- Projects admitted rows while retaining every source row with its owner.
--- @param rows any Actual persisted collection.
--- @param shapes table|nil Actual canonical decoder evidence.
--- @param mark function|nil Consumption marker.
--- @return table kept Detached admitted records with source kind evidence.
function M.partition(rows, shapes, mark)
	local kept = {}
	if type(rows) ~= "table" then
		Outdated.report(M.PATH, "a list of user model records is expected here")
		return kept
	end
	-- Historical empty table headers are an existing neutral spelling. A
	-- nonempty map never gains array ownership through that exception.
	if next(rows) == nil then
		if mark then mark("llm", "models", "user_models") end
		return LeafRows.clone_value(rows)
	end
	if not shapes or not shapes.arrays or shapes.arrays[rows] ~= true then
		Outdated.report(M.PATH, "a list of user model records is expected here")
		return kept
	end
	for index, row in ipairs(rows) do
		if M.fits(row, shapes) then
			kept[#kept + 1] = LeafRows.clone_value(row)
			if mark then mark("llm", "models", "user_models", tostring(index)) end
		else
			Outdated.report({ "llm", "models", "user_models", tostring(index) }, M.REASON)
		end
	end
	return kept
end

return M
