--- _shared/core/ui/engine/tooltip/constant_keys.lua

--- ==============================================================================
--- MODULE: Tooltip Constant Keys (Shared)
--- DESCRIPTION:
--- The required-key accessor both Lua drivers read
--- _shared/core/ui/data/tooltip/constants.toml through. A missing section or key
--- raises with its name: the constants are the single source of every tooltip
--- value, so a driver never draws with one it invented.
---
--- WHY SHARED:
--- macOS and Linux each carried their own copy of this accessor in
--- core/ui/ui/tooltip/config.lua; the copies had already drifted in their
--- messages. One reader keeps the failure the same on both.
--- ==============================================================================

local M = {}

--- Builds the accessor of one parsed constants file.
--- @param source table|function The parsed sections (section name → key →
---   value), or a function returning them, called on each read so a driver can
---   parse the file lazily.
--- @param owner string The log tag the error names, such as "[tooltip/config]".
--- @return function require_key(section, key) → value, raising when absent.
function M.reader(source, owner)
	assert(type(source) == "table" or type(source) == "function", "constant_keys.reader needs the sections")
	assert(type(owner) == "string" and owner ~= "", "constant_keys.reader needs its owner's tag")
	return function(section, key)
		local sections = type(source) == "function" and source() or source
		local values = type(sections) == "table" and sections[section] or nil
		if type(values) ~= "table" then
			error(string.format("%s missing section [%s] in the shared tooltip constants", owner, section), 2)
		end
		local value = values[key]
		if value == nil then
			error(string.format("%s missing key [%s].%s in the shared tooltip constants", owner, section, key), 2)
		end
		return value
	end
end

return M
