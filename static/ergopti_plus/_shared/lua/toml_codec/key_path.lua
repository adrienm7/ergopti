--- _shared/lua/toml_codec/key_path.lua

--- ==============================================================================
--- MODULE: TOML Table Paths (shared)
--- DESCRIPTION:
--- Decodes table segments once so codecs and byte-preserving writers agree on
--- identity. Batch paths additionally allow unquoted colons used by extension
--- owners; rendering always converts those semantic segments to valid TOML.
--- ==============================================================================

local BasicString = require("toml_codec.basic_string")
local M = {}

--- Parses a table path without brackets, rejecting partial or malformed paths.
--- @param text string Table path.
--- @param canonical boolean|nil Allow colons in owner-provided bare segments.
--- @return table|nil segments Decoded identity, or nil for invalid input.
function M.parse(text, canonical)
	if type(text) ~= "string" then return nil end
	local segments, index = {}, 1
	local function space()
		while text:sub(index, index):match("[ \t]") do index = index + 1 end
	end
	while true do
		space()
		if index > #text then return nil end
		local char, value = text:sub(index, index), nil
		if char == '"' or char == "'" then
			local start, quote = index + 1, char
			index = start
			while index <= #text and text:sub(index, index) ~= quote do
				if quote == '"' and text:sub(index, index) == "\\" then index = index + 1 end
				index = index + 1
			end
			if index > #text then return nil end
			value = text:sub(start, index - 1)
			if quote == '"' then value = BasicString.unescape_body(value)
			elseif value:find("[%z\1-\8\10-\31\127]") then return nil end
			if value == nil then return nil end
			index = index + 1
		else
			local start = index
			local pattern = canonical and "[A-Za-z0-9_:%-]" or "[A-Za-z0-9_%-]"
			while text:sub(index, index):match(pattern) do index = index + 1 end
			if start == index then return nil end
			value = text:sub(start, index - 1)
		end
		segments[#segments + 1] = value
		space()
		if index > #text then return segments end
		if text:sub(index, index) ~= "." then return nil end
		index = index + 1
	end
end

--- Renders decoded segments with unambiguous TOML quoting.
--- @param segments table Decoded table identity.
--- @return string path Canonical TOML table path.
function M.render(segments)
	local out = {}
	for index, segment in ipairs(segments) do
		out[index] = segment:match("^[A-Za-z0-9_%-]+$") and segment
			or ('"' .. BasicString.escape_body(segment) .. '"')
	end
	return table.concat(out, ".")
end

--- Finds a table header terminator outside quoted segments and validates it.
--- @param text string Trimmed physical header line, optionally with a comment.
--- @return table header Array flag and decoded segments when valid.
function M.header(text)
	local array = text:sub(1, 2) == "[["
	local start = array and 3 or 2
	local index, quote = start, nil
	while index <= #text do
		local char = text:sub(index, index)
		if quote then
			if quote == '"' and char == "\\" then index = index + 1
			elseif char == quote then quote = nil end
		elseif char == '"' or char == "'" then quote = char
		elseif char == "]" then
			local finish = array and index + 1 or index
			if array and text:sub(finish, finish) ~= "]" then break end
			local rest = text:sub(finish + 1):match("^[ \t]*(.-)[ \t]*$")
			if rest ~= "" and rest:sub(1, 1) ~= "#" then break end
			return { array = array, segments = M.parse(text:sub(start, index - 1)) }
		end
		index = index + 1
	end
	return { array = array }
end

return M
