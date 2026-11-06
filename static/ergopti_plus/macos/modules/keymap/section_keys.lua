--- modules/keymap/section_keys.lua

--- ==============================================================================
--- MODULE: Hotstring Section Cache Keys
--- DESCRIPTION:
--- Defines distinct cache identities for group and section pairs, and the
--- historical key used to read existing settings during migration.
--- ==============================================================================

local M = {}

--- Builds the historical, potentially ambiguous cache key.
--- @param group_name string
--- @param section_name string
--- @return string
function M.legacy(group_name, section_name)
	return "hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)
end

--- Builds an injective identity in a namespace distinct from historical keys.
--- @param group_name string
--- @param section_name string
--- @return string
function M.current(group_name, section_name)
	local group = tostring(group_name)
	return "hotstrings_section2_" .. #group .. "_" .. group .. tostring(section_name)
end

--- Clears both cache formats when canonical preferences are absent.
--- @param storage table Storage adapter.
--- @param group_name string
--- @param section_name string
--- @return boolean cleared
function M.clear(storage, group_name, section_name)
	local current = storage.delete(M.current(group_name, section_name))
	local legacy = storage.delete(M.legacy(group_name, section_name))
	return current == true and legacy == true
end

return M
