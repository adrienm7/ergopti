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
local BasicString = require("toml_codec.basic_string")
local Overrides = require("hotstrings.overrides")

--- Returns whether a value is one bare TOML key segment used by this schema.
--- @param value any Candidate value.
--- @return boolean valid
local function is_bare_segment(value)
	return type(value) == "string"
		and value ~= ""
		and value:match("^[%w_%-]+$") ~= nil
end

--- Canonicalizes a bare category or an ext.<id> category to its shared key.
--- @param value any Candidate category.
--- @return string|nil canonical Lowercase category key, or nil when invalid.
function M.normalize_category(value)
	return Overrides.normalize_category(value)
end

--- Returns whether a category is bare or uses the canonical ext.<id> namespace.
--- @param value any Candidate category.
--- @return boolean valid
function M.is_category(value)
	return M.normalize_category(value) ~= nil
end

--- Canonicalizes one section identifier to the shared lowercase key contract.
--- @param value any Candidate section.
--- @return string|nil canonical Lowercase key, or nil when absent/invalid.
function M.normalize_section(value)
	return Overrides.normalize_section(value)
end

--- Returns whether a section is absent or one bare TOML key segment.
--- @param value any Candidate section.
--- @return boolean valid
function M.is_section(value)
	return value == nil or M.normalize_section(value) ~= nil
end

--- Returns whether a color is a 3-to-8-digit hexadecimal CSS literal.
--- @param value any Candidate color.
--- @return boolean valid
function M.is_color(value)
	if type(value) ~= "string" or #value < 4 or #value > 9 then return false end
	return value:match("^#[0-9a-fA-F]+$") ~= nil
end

--- Returns whether a value is a finite, non-negative activation delay.
--- Zero is intentional: it means that the hotstring remains always active.
--- @param value any Candidate delay in seconds.
--- @return boolean valid
function M.is_delay(value)
	return Overrides.is_delay(value)
end

--- Validates the stored offset of a delay override: the signed seconds it adds
--- to the base expansion delay.
--- @param value any Candidate offset in seconds.
--- @return boolean valid
function M.is_delay_offset(value)
	return Overrides.is_delay_offset(value)
end

--- Encodes a string as one TOML basic-string literal.
--- @param value any Candidate string.
--- @return string|nil encoded
function M.encode_basic_string(value)
	if type(value) ~= "string" then return nil end
	return '"' .. BasicString.escape_body(value) .. '"'
end

return M
