--- _shared/lua/hotstrings/personal_scope.lua

--- ==============================================================================
--- MODULE: Personal File Scope Admission (Shared)
--- DESCRIPTION:
--- A descriptor identifies provenance, never an exclusive mutation capability.
--- Native owners supply current admission evidence before any scoped write.
--- ==============================================================================

local M = {}
local Files = require("hotstrings.personal_files")

--- Whether an inventory is a dense array without hidden entries.
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

--- Whether evidence binds an exact descriptor to one native owner and route.
--- @param value any
--- @return boolean
local function binding(value)
	return type(value) == "table" and Files.is_descriptor(value.source)
		and type(value.owner) == "string" and value.owner ~= ""
		and type(value.path) == "string" and value.path ~= ""
end

--- Admits one current exclusive binding without altering inventory or choices.
--- @param inventory table Native evidence records, with admitted/exclusive booleans.
--- @param selected table Captured source, owner and pathname binding.
--- @return table|nil binding Detached admitted binding.
--- @return string|nil reason Stable refusal identifier without user values.
function M.admit(inventory, selected)
	if not dense(inventory) or not binding(selected) then return nil, "invalid-request" end
	local found, ids = nil, {}
	for _, record in ipairs(inventory) do
		if not binding(record) or type(record.admitted) ~= "boolean" or type(record.exclusive) ~= "boolean" then
			return nil, "invalid-inventory"
		end
		if ids[record.source.id] then return nil, "duplicate-source" end
		ids[record.source.id] = true
		if record.source.id == selected.source.id then found = record end
	end
	if not found then return nil, "unknown-source" end
	if found.owner ~= selected.owner or found.path ~= selected.path then return nil, "stale-binding" end
	if not found.admitted then return nil, "unadmitted-source" end
	if not found.exclusive then return nil, "unavailable-owner" end
	for _, record in ipairs(inventory) do
		if record.admitted and record.owner == found.owner and record.source.id ~= found.source.id then
			return nil, "shared-owner"
		end
	end
	return { source = Files.copy(found.source), owner = found.owner, path = found.path }
end

return M
