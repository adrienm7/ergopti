--- platform/remap/tap_hold_shapes.lua

--- ==============================================================================
--- MODULE: Tap-Hold Table Admission (Linux)
--- DESCRIPTION:
--- Keeps obsolete scalars and arrays out of native table owners. Empty arrays
--- need the canonical decoder's exact-source receipt because the established
--- Lua document model deliberately represents both empty arrays and maps as {}.
--- ==============================================================================

local M = {}

--- Whether a value is an owned TOML dictionary, never an array container.
--- @param value any Decoded value.
--- @param shapes table|nil Canonical decoder receipt for this exact document.
--- @return boolean
function M.is_table(value, shapes)
	if type(value) ~= "table" or (shapes and shapes.arrays[value]) then return false end
	for key in pairs(value) do if type(key) ~= "string" then return false end end
	return true
end

--- Refuses a changed candidate that would replace an obsolete namespace.
--- Absent namespaces may be created; existing user records require manual repair.
--- @param value any Existing decoded value, nil when absent.
--- @param shapes table|nil Canonical receipt.
--- @param path string Exact owned path for the refusal.
function M.require_table(value, shapes, path)
	assert(value == nil or M.is_table(value, shapes), path .. " is not a table; repair the stored entry before changing it")
end

return M
