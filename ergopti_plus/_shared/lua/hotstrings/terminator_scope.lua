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

--- Returns a detached map of shipped delimiter consume defaults, excluding
--- custom rows. Only the magic-key slot ships consumed.
--- @return table consume Map of built-in key to exact boolean default.
function M.consume_defaults()
	local consume = {}
	for _, def in ipairs(Catalogue) do
		if def.key and def.custom ~= true then consume[def.key] = def.consume == true end
	end
	return consume
end

--- The leaf tables that hold one choice per shipped delimiter, in the order the
--- leaves are listed: enabled state, then consumption.
M.BUILTIN_LEAF_TABLES = { "terminator_states", "terminator_consume" }

--- Lists only stored built-in state and consume leaves. Deleting them restores
--- inheritance; personal definitions, their states, and unknown entries remain
--- user-owned.
--- @param document table Decoded config.toml.
--- @return table paths Array of path segments, each table sorted by key.
function M.builtin_state_leaves(document)
	assert(type(document) == "table", "word-delimiter leaves need a decoded configuration")
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local defaults, paths = M.defaults(), {}
	for _, name in ipairs(M.BUILTIN_LEAF_TABLES) do
		local stored = hotstrings[name]
		if type(stored) == "table" and not (next(stored) ~= nil and #stored > 0) then
			local keys = {}
			for key in pairs(stored) do
				if type(key) == "string" and defaults[key] ~= nil then keys[#keys + 1] = key end
			end
			table.sort(keys)
			for _, key in ipairs(keys) do paths[#paths + 1] = { "hotstrings", name, key } end
		end
	end
	return paths
end

return M
