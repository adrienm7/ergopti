--- drivers/_shared/lua/keymap/utils.lua

--- ==============================================================================
--- MODULE: Keymap Utilities (Shared)
--- DESCRIPTION:
--- Platform-neutral helper functions for the keymap module: replacement token
--- parsing, plain-text extraction from token lists, and LLM prediction overlap
--- resolution. These functions depend only on the Lua 5.3+ standard library
--- and the shared text_utils module — no Hammerspoon or OS-specific API.
---
--- FEATURES & RATIONALE:
--- 1. Token Parsing: tokens_from_repl() converts raw replacement strings
---    containing {Placeholder} directives into structured action lists,
---    enabling both preview rendering and OS-layer emission.
--- 2. Plain-Text Extraction: plain_text() reconstructs the visible text from
---    a token list, used to pre-compute plain_repl at load time so the hot
---    path never re-tokenizes.
--- 3. Overlap Solver: resolve_prediction_overlap() aligns an LLM completion
---    with the current buffer to prevent ghost-text duplication, handling
---    French accents, spaces, apostrophes, and compound words.
--- ==============================================================================

local M          = {}
local text_utils = require("text_utils")
local LOG        = "keymap.utils"

local Logger = require("logger.shim")




-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

-- Mapping from {Placeholder} names inside replacement strings to key action names.
-- The values match hs.eventtap key names on Hammerspoon; Linux drivers map them
-- to their own equivalents via the same token kind="key" entries.
local KEY_COMMANDS = {
	Left      = "left",          Right     = "right",
	Up        = "up",            Down      = "down",
	Home      = "home",          End       = "end",
	Delete    = "forwarddelete", Del       = "forwarddelete",
	Backspace = "delete",        BackSpace = "delete", BS = "delete",
	Tab       = "tab",
	Enter     = "return",        Return    = "return",
	Escape    = "escape",        Esc       = "escape",
}




-- ======================================
--- ======================================
-- ======= 2/ Token Parsing & Text =======
--- ======================================
-- ======================================

--- Splits a plain-text segment on newlines and pushes the result as tokens.
--- Each "\n" becomes a {kind="key", value="return"} token.
--- @param tokens table Destination token array.
--- @param text string The string to split and append.
local function push_text_tokens(tokens, text)
	if type(text) ~= "string" or type(tokens) ~= "table" then return end

	local first = true
	for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
		if not first then table.insert(tokens, { kind = "key", value = "return" }) end
		if segment ~= "" then table.insert(tokens, { kind = "text", value = segment }) end
		first = false
	end
end

--- Parses a replacement string containing optional {Placeholder} directives into
--- a list of action tokens. Unknown placeholders are kept as literal text.
---
--- Example:
---   "Hello{Enter}World" → [{kind="text", value="Hello"}, {kind="key", value="return"}, {kind="text", value="World"}]
---
--- @param repl string The raw replacement string.
--- @return table An array of {kind, value} token tables.
function M.tokens_from_repl(repl)
	if type(repl) ~= "string" then
		Logger.error(LOG, "tokens_from_repl: repl must be a string (got %s).", type(repl))
		return {}
	end

	local tokens = {}
	local i      = 1

	while i <= #repl do
		local s, e, name = repl:find("{(%w+)}", i)
		if s then
			if s > i then push_text_tokens(tokens, repl:sub(i, s - 1)) end
			-- Match case-insensitively: {enter}, {ENTER}, {Enter} all work.
			local title  = name:sub(1, 1):upper() .. name:sub(2):lower()
			local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
			if hs_key then
				table.insert(tokens, { kind = "key", value = hs_key })
			else
				-- Unknown placeholder — treat literally rather than silently dropping it
				table.insert(tokens, { kind = "text", value = "{" .. name .. "}" })
			end
			i = e + 1
		else
			push_text_tokens(tokens, repl:sub(i))
			break
		end
	end

	return tokens
end

--- Reconstructs the plain-text string from a token list by concatenating all
--- text tokens (i.e., skipping key tokens like {Enter}).
--- @param tokens table The token list.
--- @return string The combined visible text.
function M.plain_text(tokens)
	if type(tokens) ~= "table" then return "" end
	local parts = {}
	for _, tok in ipairs(tokens) do
		if type(tok) == "table" and tok.kind == "text" and type(tok.value) == "string" then
			table.insert(parts, tok.value)
		end
	end
	return table.concat(parts)
end




-- ================================================
--- ================================================
-- ======= 3/ LLM Prediction Overlap Solver =======
--- ================================================
-- ================================================

--- Computes the correct number of deletions and the text to type in order to
--- apply an LLM completion without duplicating text the user has already typed.
---
--- Algorithm:
---   1. Strip accents and normalize both the end of the buffer and the start of
---      the prediction for a robust, accent-insensitive comparison.
---   2. Use a sliding window to find the longest suffix of the buffer that matches
---      a prefix of the prediction (overlap).
---   3. If an overlap is found, delete exactly those chars and type the rest.
---   4. Fix up separator logic so the result reads naturally, handling:
---      - Double-space prevention (buffer already ends with space).
---      - Missing-space insertion (buffer ends with a word, prediction starts with a word).
---      - Compound-word continuations (buffer ends with "-", no separator needed).
---      - Contraction handling (buffer ends with apostrophe, no separator needed).
---      - Punctuation that must not be preceded by a regular space.
---
--- @param buffer string The current typing buffer.
--- @param pred_deletes number The AI's suggested number of deletions.
--- @param pred_to_type string The AI's suggested completion text.
--- @return number, string The corrected deletion count and the safe text to append.
function M.resolve_prediction_overlap(buffer, pred_deletes, pred_to_type)
	Logger.trace(LOG, "Resolving prediction overlap…")

	local orig_deletes = tonumber(pred_deletes) or 0
	local to_type      = type(pred_to_type) == "string" and pred_to_type or ""

	if to_type == "" then
		Logger.done(LOG, "Empty prediction — nothing to resolve.")
		return orig_deletes, to_type
	end

	-- Strip zero-width spaces from the buffer (used elsewhere as invisible markers).
	local buf_str = type(buffer) == "string" and buffer:gsub("\u{200B}", "") or ""

	-- Strip leading whitespace from the prediction for overlap matching only.
	-- The original leading space is restored later if context requires it.
	local tt_trim = to_type:gsub("^[%s\194\160\226\128\175]+", "")

	--- Removes French accents and normalizes for accent-insensitive overlap matching.
	--- @param s string
	--- @return string
	local function normalize(s)
		local map = {
			["à"] = "a", ["â"] = "a", ["ä"] = "a",
			["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e",
			["î"] = "i", ["ï"] = "i",
			["ô"] = "o", ["ö"] = "o",
			["ù"] = "u", ["û"] = "u", ["ü"] = "u",
			["ç"] = "c", ["œ"] = "oe", ["æ"] = "ae",
		}
		s = s:lower():gsub("\u{2019}", "'")
		local chars = text_utils.utf8_chars(s)
		for k, c in ipairs(chars) do chars[k] = map[c] or c end
		return table.concat(chars)
	end

	local cb_norm = normalize(buf_str)
	local tt_norm = normalize(tt_trim)

	local deletes = orig_deletes

	local ok_cb_len, cb_len = pcall(text_utils.utf8_len, cb_norm)
	if not ok_cb_len or cb_len == 0 then
		Logger.done(LOG, "Buffer empty — keeping original LLM instruction.")
		return orig_deletes, pred_to_type
	end

	-- Sliding window: find the longest suffix of the normalized buffer that
	-- equals a prefix of the normalized prediction (capped at 40 chars to bound cost).
	local best_overlap = 0
	local search_limit = math.min(cb_len, 40)

	for i = 1, search_limit do
		local ok_s, suffix = pcall(text_utils.utf8_sub, cb_norm, -i)
		local ok_p, prefix = pcall(text_utils.utf8_sub, tt_norm, 1, i)
		if ok_s and ok_p and suffix == prefix then
			best_overlap = i
		end
	end

	if best_overlap > 0 then
		deletes = best_overlap
		to_type = tt_trim

		-- When the original prediction started with a space and we trimmed it,
		-- restore that space only if the context before the overlap has no space —
		-- otherwise we would produce a double space.
		-- Also skip restoration when the entire buffer is consumed by the overlap
		-- (buffer_before_overlap would be empty, meaning there's no preceding context
		-- that could need a separator).
		local orig_starts_with_space = pred_to_type:match("^[%s\194\160\226\128\175]") ~= nil
		if orig_starts_with_space then
			local buffer_before_overlap = text_utils.utf8_sub(buf_str, 1, cb_len - best_overlap)
			local ends_with_space       = buffer_before_overlap:match("[%s\194\160\226\128\175]$") ~= nil
			if not ends_with_space and buffer_before_overlap ~= "" then
				to_type = " " .. to_type
			end
		end
	else
		-- No overlap detected — trust the AI's original instruction completely.
		deletes = orig_deletes
		to_type = pred_to_type
	end

	-- Fix spacing at the join point: remove double-spaces only.
	-- Space insertion is the parser's responsibility — we must not add spaces here
	-- or mid-word completions (e.g. "attentio" + "n suite") would get a spurious
	-- space inserted before the continuation character.
	if deletes == 0 and to_type ~= "" then
		local b_last  = text_utils.utf8_sub(buf_str, -1)
		local p_first = text_utils.utf8_sub(to_type, 1, 1)

		-- Characters after which a leading space on the prediction is redundant:
		-- whitespace, apostrophes (contractions: "l'idée"), hyphens (compound
		-- words: "anti-spam"), opening brackets (don't insert space inside them).
		local ends_no_sep = b_last:match("[%s''%-%(%[]")
			or b_last == "\194\160" or b_last == "\226\128\175"

		-- Prediction starts with whitespace — detect to remove double-spaces.
		local starts_with_space = p_first:match("[%s]")
			or p_first == "\194\160" or p_first == "\226\128\175"

		if ends_no_sep and starts_with_space then
			-- Strip the leading space to avoid double-space (or unwanted space after
			-- a hyphen, apostrophe, etc.).
			to_type = to_type:gsub("^[%s\194\160\226\128\175]+", "")
		end
	end

	Logger.done(LOG, "Overlap resolved: %d deletion(s), '%s'.", deletes, to_type)
	return deletes, to_type
end


return M
