--- _shared/lua/toml_codec/bom.lua

--- ==============================================================================
--- MODULE: TOML UTF-8 BOM Helper (shared)
--- DESCRIPTION:
--- Removes one UTF-8 byte-order mark only when it is the exact stream prefix.
--- Mid-stream BOM bytes remain ordinary data and are never rewritten.
--- ==============================================================================

local M = {}

local UTF8_BOM = string.char(0xEF, 0xBB, 0xBF)

--- Removes one UTF-8 BOM from the start of a TOML stream fragment.
--- @param value string Any complete source or first physical line.
--- @return string value The input without its exact leading BOM.
function M.strip_prefix(value)
	if type(value) ~= "string" then return value end
	if value:sub(1, #UTF8_BOM) == UTF8_BOM then
		return value:sub(#UTF8_BOM + 1)
	end
	return value
end

return M
