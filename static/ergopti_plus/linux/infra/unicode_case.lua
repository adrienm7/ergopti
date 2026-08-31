--- infra/unicode_case.lua

--- ==============================================================================
--- MODULE: Unicode Case Conversion (Linux)
--- DESCRIPTION:
--- Applies complete generated Unicode case mappings without locale-dependent
--- subprocesses. LuaJIT string.upper/string.lower are byte-oriented and leave
--- every non-ASCII letter unchanged, which broke selection transforms.
--- ==============================================================================

local M = {}

local Data = require("_generated.unicode_case_data")

local UTF8_CHARACTER = "[%z\1-\127\194-\244][\128-\191]*"

M.UNICODE_VERSION = Data.unicode_version

--- Whether text contains exactly one valid UTF-8 character.
--- @param text string
--- @return boolean
function M.is_single_character(text)
	return type(text) == "string" and text:match("^" .. UTF8_CHARACTER .. "$") ~= nil
end

--- Whether a character ends a CapsWord word.
--- @param character string
--- @return boolean
function M.is_word_boundary(character)
	return M.is_single_character(character) and Data.boundary[character] == true
end

--- Applies one generated mapping without changing invalid or uncased bytes.
--- @param text string
--- @param mapping table
--- @return string
local function apply(text, mapping)
	if type(text) ~= "string" then return "" end
	return (text:gsub(UTF8_CHARACTER, function(character)
		return mapping[character] or character
	end))
end

--- Converts text with Unicode default uppercase mappings.
--- @param text string
--- @return string
function M.upper(text)
	return apply(text, Data.upper)
end

--- Converts text with Unicode default lowercase mappings.
--- @param text string
--- @return string
function M.lower(text)
	if type(text) ~= "string" then return "" end
	local characters = {}
	for character in text:gmatch(UTF8_CHARACTER) do
		characters[#characters + 1] = character
	end
	local function is_cased(character)
		return Data.upper[character] ~= nil or Data.lower[character] ~= nil
	end
	local cased_before = {}
	local preceding_is_cased = false
	for index, character in ipairs(characters) do
		cased_before[index] = preceding_is_cased
		if not Data.case_ignorable[character] then
			preceding_is_cased = is_cased(character)
		end
	end
	local cased_after = {}
	local following_is_cased = false
	for index = #characters, 1, -1 do
		local character = characters[index]
		cased_after[index] = following_is_cased
		if not Data.case_ignorable[character] then
			following_is_cased = is_cased(character)
		end
	end
	local index = 0
	return (text:gsub(UTF8_CHARACTER, function(character)
		index = index + 1
		if character == "Σ" and cased_before[index] and not cased_after[index] then
			return "ς"
		end
		return Data.lower[character] or character
	end))
end

--- Whether text contains a cased character that is not already uppercase.
--- @param text string
--- @return boolean
function M.has_lowercase(text)
	if type(text) ~= "string" then return false end
	for character in text:gmatch(UTF8_CHARACTER) do
		if Data.upper[character] then return true end
	end
	return false
end

--- Converts each whitespace-delimited word to Unicode title case.
--- Punctuation before a word remains intact and does not consume its first letter.
--- @param text string
--- @return string
function M.title(text)
	if type(text) ~= "string" then return "" end
	local at_word_start = true
	local lowered = M.lower(text)
	return (lowered:gsub(UTF8_CHARACTER, function(character)
		if character:match("^%s$") then
			at_word_start = true
			return character
		end
		if at_word_start and Data.title[character] then
			at_word_start = false
			return Data.title[character] or character
		end
		return character
	end))
end

return M
