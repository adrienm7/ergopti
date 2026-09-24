--- _shared/lua/unicode_case/init.lua

--- ==============================================================================
--- MODULE: Unicode Case Conversion (shared)
--- DESCRIPTION:
--- Converts text with the complete Unicode default case mappings, generated
--- into unicode_case/data.lua, and implements the selection case
--- actions' rules once for the macOS and Linux drivers. Lua's string.upper and
--- string.lower work on bytes and leave every non-ASCII letter unchanged, which
--- broke the selection transforms on both drivers.
---
--- FEATURES & RATIONALE:
--- 1. No locale, no subprocess: the table is pure data, so the result is the
---    same on every machine.
--- 2. One title-case rule, pinned by _shared/tests/corpus/text_case/vectors.json,
---    which the Windows suite replays against its own implementation too.
--- ==============================================================================

local M = {}

local Data = require("unicode_case.data")

local UTF8_CHARACTER = "[%z\1-\127\194-\244][\128-\191]*"

M.UNICODE_VERSION = Data.unicode_version

--- Whether text contains exactly one valid UTF-8 character.
--- @param text string
--- @return boolean
function M.is_single_character(text)
	return type(text) == "string" and text:match("^" .. UTF8_CHARACTER .. "$") ~= nil
end

--- Whether a character ends a CapsWord word (Unicode whitespace or punctuation).
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

--- Converts text with Unicode default lowercase mappings, including the
--- contextual Greek final sigma.
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

--- Converts text to title case. A word starts at the beginning of the text and
--- after whitespace or a dash, so "jean-pierre" becomes "Jean-Pierre". Other
--- punctuation before a word ("«", "(", a quote) is kept and does not consume
--- the capital; an apostrophe inside a word does not start a new one, so
--- "l'été" becomes "L'été". A digit or symbol that starts a word ends the word
--- start: "3e" stays "3e".
--- @param text string
--- @return string
function M.title(text)
	if type(text) ~= "string" then return "" end
	local at_word_start = true
	return (M.lower(text):gsub(UTF8_CHARACTER, function(character)
		if Data.word_separator[character] then
			at_word_start = true
			return character
		end
		if not at_word_start or Data.boundary[character] then return character end
		at_word_start = false
		return Data.title[character] or character
	end))
end

--- The uppercase toggle: uppercase when any character can still be
--- uppercased, lowercase otherwise, so pressing the action twice undoes it.
--- @param text string
--- @return string
function M.toggle_upper(text)
	if M.has_lowercase(text) then return M.upper(text) end
	return M.lower(text)
end

--- The title-case toggle: lowercase when the text is already in title case,
--- title case otherwise.
--- @param text string
--- @return string
function M.toggle_title(text)
	local titled = M.title(text)
	if titled == text then return M.lower(text) end
	return titled
end

return M
