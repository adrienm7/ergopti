--- _shared/lua/shortcuts/physical_availability.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Admission
--- DESCRIPTION:
--- Separates GUI readiness from native source, all-owner collision and output
--- capability. Disabled mappings and removal retain their established publisher.
--- ==============================================================================

local Slots = require("shortcuts.physical_slots")
local M = {}

--- Accepts only a strict native capability acknowledgement.
--- @param query function Native capability getter; no GUI or configuration work.
--- @return boolean ready False also covers missing, unknown and throwing ports.
function M.ready(query)
	if type(query) ~= "function" then return false end
	local called, available = pcall(query)
	return called and available == true
end

--- Captures immutable scalar rows before native admission callbacks can change them.
--- Existing publishers remain responsible for field/domain and duplicate validation.
--- @param rows table Caller-owned dense update array.
--- @return table|nil captured Detached plain scalar rows, or a malformed refusal.
function M.capture_updates(rows)
	if type(rows) ~= "table" or getmetatable(rows) ~= nil or #rows == 0 then return nil end
	local captured, count = {}, 0
	for index, row in pairs(rows) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #rows
			or type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
		local copy = {}
		for key, value in pairs(row) do
			local kind = type(value)
			if type(key) ~= "string" or kind ~= "string" and kind ~= "boolean" and kind ~= "number" then return nil end
			copy[key] = value
		end
		captured[index], count = copy, count + 1
	end
	if count ~= #rows then return nil end
	return captured
end

--- Identifies writes that need native physical delivery before publication.
--- Unknown records remain the established publisher's validation responsibility.
--- @param rows table Sparse updates owned by the configuration publisher.
--- @param parameter_section string Native canonical action parameter section.
--- @param split function Actual action catalogue parameter-key decoder.
--- @return boolean required Active mapping or its nondeleted parameter.
function M.requires_delivery(rows, parameter_section, split)
	for _, row in ipairs(rows) do
		if type(row) == "table" and row.delete ~= true then
			if row.section == "shortcuts.keyboard" and Slots.is_namespace(row.key) and row.value ~= "none" then return true end
			if row.section == parameter_section and type(row.key) == "string" then
				local called, binding = pcall(split, row.key)
				if not called then return true end
				local slot = type(binding) == "string" and binding:match("^keyboard__(.+)$") or nil
				if Slots.is_namespace(slot) then return true end
			end
		end
	end
	return false
end

return M
