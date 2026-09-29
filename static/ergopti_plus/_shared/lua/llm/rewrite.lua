--- _shared/lua/llm/rewrite.lua

--- ==============================================================================
--- MODULE: Rewrite Request Helpers — Shared Lua Implementation
--- DESCRIPTION:
--- Pure helpers for "rewrite" prompts: prompts that ask the model to rewrite the
--- sentence being typed (expand abbreviations, fix spelling, punctuation and
--- typography) instead of predicting the next words.
---
--- FEATURES & RATIONALE:
--- 1. A rewrite prompt is recognised by its output tag ("REWRITE:"), the same
---    prompt-sniffing convention as PREFIX/TAIL and TAIL_CORRECTED. A user prompt
---    cloned from the built-in rewrite profile therefore behaves as one too,
---    without a new profile field every driver would have to validate.
--- 2. The rewritten span is the current sentence: the buffer suffix after the
---    last sentence terminator that is followed by spacing, or after the last
---    line break. A sentence that was just finished ("… jeudi.") is still the
---    current one, so the shortcut rewrites what the user has just typed.
--- 3. The span is an exact suffix of the buffer, so the parser can align the
---    rewrite against it and erase exactly the characters it replaces.
--- 4. The token budget grows with the span, because the continuation budget
---    (a few words) would truncate a rewritten sentence.
---
--- The AutoHotkey port is windows/modules/llm/rewrite.ahk. Both are pinned by
--- _shared/tests/corpus/llm/rewrite_vectors.json.
--- ==============================================================================

local M = {}

local text_utils = require("text_utils")
local native_utf8 = rawget(_G, "utf8")
local utf8_lib = (type(native_utf8) == "table" and native_utf8.codes and native_utf8.char)
	and native_utf8 or require("compat.utf8")




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Output tag a rewrite prompt asks for; its presence in the system prompt is
-- what makes a profile a rewrite profile
M.OUTPUT_TAG = "REWRITE:"

-- Characters that end a sentence when spacing follows them
M.SENTENCE_TERMINATORS = { ".", "!", "?", "\226\128\166" }

-- Floor of the rewrite token budget, enough for a short rewritten sentence
M.MIN_MAX_TOKENS = 64

-- Tokens budgeted per codepoint of the span: abbreviations expand to several
-- times their typed length, and a truncated rewrite would erase text it
-- cannot retype
M.TOKENS_PER_CHAR = 2

-- Fixed overhead for the output tag and the model's spacing
M.TOKEN_BUDGET_OVERHEAD = 16




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Tells whether a system prompt asks for a rewrite instead of a continuation.
--- @param system_prompt string|nil The profile's system prompt or raw prompt.
--- @return boolean is_rewrite True when the prompt requests the rewrite tag.
function M.is_rewrite_prompt(system_prompt)
	if type(system_prompt) ~= "string" then return false end
	return system_prompt:find(M.OUTPUT_TAG, 1, true) ~= nil
end

--- Tells whether a profile is a rewrite profile, from whichever prompt it uses.
--- @param profile table|nil A profile record (system_single and/or raw_prompt).
--- @return boolean is_rewrite True when one of its prompts requests the rewrite tag.
function M.is_rewrite_profile(profile)
	if type(profile) ~= "table" then return false end
	return M.is_rewrite_prompt(profile.raw_prompt) or M.is_rewrite_prompt(profile.system_single)
end

--- Returns the character array of a string, or raises on malformed UTF-8.
--- @param value string The text to split.
--- @return table chars One entry per codepoint.
local function chars_of(value)
	local chars = {}
	for _, code in utf8_lib.codes(value) do chars[#chars + 1] = utf8_lib.char(code) end
	return chars
end

--- Tells whether a character is spacing (space, tab, NBSP, NNBSP, line break).
--- @param char string One codepoint.
--- @return boolean is_spacing
local function is_spacing(char)
	return char == " " or char == "\t" or char == "\n" or char == "\r"
		or char == "\194\160" or char == "\226\128\175"
end

--- Tells whether a character ends a sentence.
--- @param char string One codepoint.
--- @return boolean is_terminator
local function is_terminator(char)
	for _, terminator in ipairs(M.SENTENCE_TERMINATORS) do
		if char == terminator then return true end
	end
	return false
end

--- Returns the current sentence: the suffix of the buffer to rewrite.
--- Trailing spacing and the sentence's own final terminators belong to the
--- span; the scan starts before them so a just-finished sentence is kept.
--- @param buffer string The typed text, most recent character last.
--- @return string span Exact suffix of buffer, without leading spacing ("" when blank).
function M.sentence_span(buffer)
	if type(buffer) ~= "string" then
		error("sentence_span expects a string buffer, got " .. type(buffer))
	end
	local chars = chars_of(buffer)
	local index = #chars
	while index >= 1 and is_spacing(chars[index]) do index = index - 1 end
	while index >= 1 and is_terminator(chars[index]) do index = index - 1 end

	local start = 1
	for i = index, 1, -1 do
		local char = chars[i]
		if char == "\n" or char == "\r" then
			start = i + 1
			break
		end
		if is_spacing(char) and i > 1 and is_terminator(chars[i - 1]) then
			start = i + 1
			break
		end
	end
	while start <= #chars and is_spacing(chars[start]) do start = start + 1 end
	if start > index then return "" end
	return table.concat(chars, "", start)
end

--- Returns the completion token budget for rewriting a span.
--- @param span string The sentence to rewrite.
--- @return number max_tokens Budget large enough to retype the expanded sentence.
function M.max_tokens(span)
	local length = text_utils.utf8_len(type(span) == "string" and span or "")
	return math.max(M.MIN_MAX_TOKENS, length * M.TOKENS_PER_CHAR + M.TOKEN_BUDGET_OVERHEAD)
end

return M
