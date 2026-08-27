--- modules/hotstrings/hotstrings_config_schema.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Schema
--- DESCRIPTION:
--- Owns the untrusted string contract shared by the hotstrings configuration
--- bridge and persistence layer. Identifiers must remain bare TOML path segments,
--- colors are hexadecimal CSS literals, and string values are encoded as TOML
--- basic strings before they reach a record editor or complete-file serializer.
--- ==============================================================================

local M = {}

--- Returns whether a value is one bare TOML key segment used by this schema.
--- @param value any Candidate value.
--- @return boolean valid
local function is_bare_segment(value)
	return type(value) == "string"
		and value ~= ""
		and value:match("^[%w_%-]+$") ~= nil
end

--- Returns whether a category is bare or uses the canonical ext.<id> namespace.
--- @param value any Candidate category.
--- @return boolean valid
function M.is_category(value)
	if is_bare_segment(value) then return true end
	if type(value) ~= "string" then return false end
	local extension_id = value:match("^ext%.([%w_%-]+)$")
	return is_bare_segment(extension_id)
end

--- Returns whether a section is absent or one bare TOML key segment.
--- @param value any Candidate section.
--- @return boolean valid
function M.is_section(value)
	return value == nil or is_bare_segment(value)
end

--- Returns whether a color is a 3-to-8-digit hexadecimal CSS literal.
--- @param value any Candidate color.
--- @return boolean valid
function M.is_color(value)
	if type(value) ~= "string" or #value < 4 or #value > 9 then return false end
	return value:match("^#[0-9a-fA-F]+$") ~= nil
end

--- Encodes a string as one TOML basic-string literal.
--- @param value any Candidate string.
--- @return string|nil encoded
function M.encode_basic_string(value)
	if type(value) ~= "string" then return nil end
	local escaped = value:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\t", "\\t")
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
	return '"' .. escaped .. '"'
end

return M
