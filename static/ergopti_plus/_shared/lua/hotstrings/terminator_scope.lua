--- _shared/lua/hotstrings/terminator_scope.lua

--- ==============================================================================
--- MODULE: Hotstring Delimiter Scope Policy (Shared)
--- DESCRIPTION:
--- Restores shipped word-delimiter defaults without deleting personal delimiters
--- or outdated entries. Both Lua drivers use the same catalogue and leaf plan;
--- their transaction owners retain file publication and runtime rollback.
--- ==============================================================================

local M = {}
local Catalogue = require("keymap.terminators_catalogue")

--- Returns a detached map of shipped delimiter defaults, excluding custom rows.
--- @return table states Map of built-in key to exact boolean default.
function M.defaults()
	local states = {}
	for _, def in ipairs(Catalogue) do
		if def.key and def.custom ~= true then states[def.key] = def.default_enabled ~= false end
	end
	return states
end

--- Lists only stored built-in state leaves. Deleting them restores inheritance;
--- personal definitions, their states, and unknown entries remain user-owned.
--- @param document table Decoded config.toml.
--- @return table paths Sorted array of path segments.
function M.builtin_state_leaves(document)
	assert(type(document) == "table", "word-delimiter leaves need a decoded configuration")
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local states = hotstrings.terminator_states
	if type(states) ~= "table" or (next(states) ~= nil and #states > 0) then return {} end
	local defaults, keys = M.defaults(), {}
	for key in pairs(states) do
		if type(key) == "string" and defaults[key] ~= nil then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local paths = {}
	for _, key in ipairs(keys) do paths[#paths + 1] = { "hotstrings", "terminator_states", key } end
	return paths
end

return M
