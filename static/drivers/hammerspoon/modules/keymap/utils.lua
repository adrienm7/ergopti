--- modules/keymap/utils.lua

--- ==============================================================================
--- MODULE: Keymap Utilities
--- DESCRIPTION:
--- Provides helper functions for the main keymap engine, offloading
--- complex logic such as text emission (simulated keystrokes vs clipboard paste),
--- token parsing, LLM prediction overlap resolution, and ignored window detection.
---
--- FEATURES & RATIONALE:
--- 1. Safe Emission: Chooses between direct keystrokes or fast clipboard pasting.
--- 2. Seamless LLM Integration: Computes overlap to prevent ghost text duplication.
--- ==============================================================================

local hs = hs
local M = {}

local text_utils = require("lib.text_utils")
local eventtap   = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke
local Logger     = require("lib.logger")

local LOG = "keymap.utils"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local PASTE_THRESHOLD = 50

local KEY_COMMANDS = {
	Left = "left", Right = "right", Up = "up", Down = "down",
	Home = "home", End = "end",
	Delete = "forwarddelete", Del = "forwarddelete",
	Backspace = "delete", BackSpace = "delete", BS = "delete",
	Tab = "tab", Enter = "return", Return = "return",
	Escape = "escape", Esc = "escape",
}





-- ==========================================
-- ==========================================
-- ======= 2/ Text Emission Utilities =======
-- ==========================================
-- ==========================================

--- Determines whether a string should be pasted via clipboard rather than typed.
--- @param text string The text to evaluate.
--- @return boolean True if the text is long or contains complex unicode.
function M.should_paste(text)
	if type(text) ~= "string" then return false end
	local ok, len = pcall(text_utils.utf8_len, text)
	if ok and len > PASTE_THRESHOLD then return true end
	
	local ok_high, has_high = pcall(text_utils.contains_high_unicode, text)
	if ok_high and has_high then return true end
	
	return false
end

--- Internal helper to extract plain text and newlines into actionable tokens.
--- @param tokens table The target table.
--- @param text string The string to parse.
local function push_text_tokens(tokens, text)
	if type(text) ~= "string" or type(tokens) ~= "table" then return end
	
	local first = true
	for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
		if not first then table.insert(tokens, { kind = "key", value = "return" }) end
		if segment ~= "" then table.insert(tokens, { kind = "text", value = segment }) end
		first = false
	end
end

--- Parses a replacement string into keystrokes and plain text segments.
--- @param repl string The raw replacement string (e.g. "Hello {Enter} World").
--- @return table A list of parsed tokens.
function M.tokens_from_repl(repl)
	local tokens = {}
	if type(repl) ~= "string" then return tokens end
	
	local i = 1
	while i <= #repl do
		local s, e, name = repl:find("{(%w+)}", i)
		if s then
			if s > i then push_text_tokens(tokens, repl:sub(i, s - 1)) end
			local title  = name:sub(1,1):upper() .. name:sub(2):lower()
			local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
			if hs_key then
				table.insert(tokens, { kind = "key", value = hs_key })
			else
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

--- Emits a sequence of parsed tokens (typing or pasting as necessary).
--- @param tokens table The tokens to emit.
--- @return number, string The total characters emitted and the raw string representation.
function M.emit_tokens(tokens)
	local count = 0
	local emitted_str = ""
	if type(tokens) ~= "table" then return count, emitted_str end

	for _, tok in ipairs(tokens) do
		if type(tok) == "table" then
			if tok.kind == "key" then
				keyStroke({}, tok.value, 0)
				count = count + 1
			elseif M.should_paste(tok.value) then
				local prev = hs.pasteboard.getContents()
				hs.pasteboard.setContents(tok.value)
				keyStroke({ "cmd" }, "v", 0)
				count = count + 1
				
				-- Restore user clipboard safely after a generous delay to prevent race conditions
				hs.timer.doAfter(1.5, function() 
					pcall(function() hs.pasteboard.setContents(prev or "") end)
				end)
			else
				keyStrokes(tok.value)
				local ok, len = pcall(text_utils.utf8_len, tok.value)
				count = count + (ok and len or 1)
				emitted_str = emitted_str .. tok.value
			end
		end
	end
	
	return count, emitted_str
end

--- Emits a raw string (typing or pasting as necessary).
--- @param text string The text to emit.
--- @return number, string The total characters emitted and the string itself.
function M.emit_text(text)
	if type(text) ~= "string" then return 0, "" end
	
	if M.should_paste(text) then
		local prev = hs.pasteboard.getContents()
		hs.pasteboard.setContents(text)
		keyStroke({ "cmd" }, "v", 0)
		
		-- Restore user clipboard safely after a generous delay to prevent race conditions
		hs.timer.doAfter(1.5, function() 
			pcall(function() hs.pasteboard.setContents(prev or "") end)
		end)
		
		return 1, ""
	end
	
	keyStrokes(text)
	local ok, len = pcall(text_utils.utf8_len, text)
	return (ok and len or 1), text
end

--- Reconstructs the plain string representation of a token list.
--- @param tokens table The token list.
--- @return string The combined plain text.
function M.plain_text(tokens)
	local parts = {}
	if type(tokens) == "table" then
		for _, tok in ipairs(tokens) do
			if type(tok) == "table" and tok.kind == "text" and type(tok.value) == "string" then 
				table.insert(parts, tok.value) 
			end
		end
	end
	return table.concat(parts)
end





-- ================================================
-- ================================================
-- ======= 3/ LLM Prediction Overlap Solver =======
-- ================================================
-- ================================================

--- Calculates the optimal deletion count and text to type to seamlessly insert an LLM prediction.
--- Uses a robust, accent-insensitive sliding window to perfectly merge the current buffer with the prediction.
--- @param buffer string The current typing buffer.
--- @param pred_deletes number The AI’s suggested deletion count.
--- @param pred_to_type string The AI’s suggested string to append.
--- @return number, string The corrected deletion count and the safe string to append.
function M.resolve_prediction_overlap(buffer, pred_deletes, pred_to_type)
	Logger.debug(LOG, "Resolving prediction overlap…")
	local orig_deletes = tonumber(pred_deletes) or 0
	local to_type = type(pred_to_type) == "string" and pred_to_type or ""

	if to_type == "" then return orig_deletes, to_type end

	local buf_str = type(buffer) == "string" and buffer or ""
	local cb = buf_str:gsub("​", "") 
	
	-- Strip spaces for overlap checking to avoid solver bugs
	local tt_trim = to_type:gsub("^[%s\194\160\226\128\175]+", "")
	
	-- Helper to remove accents and normalize text for strict overlap checking
	local function normalize(s)
		local map = {
			["à"]="a", ["â"]="a", ["ä"]="a",
			["é"]="e", ["è"]="e", ["ê"]="e", ["ë"]="e",
			["î"]="i", ["ï"]="i",
			["ô"]="o", ["ö"]="o",
			["ù"]="u", ["û"]="u", ["ü"]="u",
			["ç"]="c", ["œ"]="oe", ["æ"]="ae"
		}
		s = s:lower():gsub("'", "’")
		local chars = text_utils.utf8_chars(s)
		for k, c in ipairs(chars) do
			chars[k] = map[c] or c
		end
		return table.concat(chars)
	end

	local cb_norm = normalize(cb)
	local tt_norm = normalize(tt_trim)

	local deletes = orig_deletes

	local ok_cb_len, cb_len = pcall(text_utils.utf8_len, cb_norm)
	if ok_cb_len and cb_len > 0 then
		local best_overlap = 0
		local search_limit = math.min(cb_len, 40)
		
		-- Sliding window to find the longest matching sequence between the end of buffer and start of prediction
		for i = 1, search_limit do
			local ok_sub, suffix = pcall(text_utils.utf8_sub, cb_norm, -i)
			local ok_pre, prefix = pcall(text_utils.utf8_sub, tt_norm, 1, i)
			if ok_sub and ok_pre and suffix == prefix then
				best_overlap = i
			end
		end
		
		if best_overlap > 0 then
			deletes = best_overlap
			to_type = tt_trim
			
			-- If we matched an overlap (user typed ahead) and trimmed the AI’s leading space,
			-- we MUST restore it if the buffer right before the overlap does NOT have a space
			local orig_starts_with_space = pred_to_type:match("^[%s\194\160\226\128\175]") ~= nil
			if orig_starts_with_space then
				local buffer_before_overlap = text_utils.utf8_sub(cb, 1, cb_len - best_overlap)
				local ends_with_space = buffer_before_overlap:match("[%s\194\160\226\128\175]$") ~= nil
				if not ends_with_space then
					to_type = " " .. to_type
				end
			end
		else
			-- Fallback: The LLM instructions are completely trusted if no overlap is found
			deletes = orig_deletes
			to_type = pred_to_type
		end
	end

	-- Correct spacing and punctuation logic preventing collapsed phrasing OR double spaces
	if deletes == 0 and to_type ~= "" then
		local b_last = text_utils.utf8_sub(cb, -1)
		local p_first = text_utils.utf8_sub(to_type, 1, 1)
		
		local ends_with_space   = b_last:match("[%s'’]") or b_last == "\194\160" or b_last == "\226\128\175"
		local starts_with_space = p_first:match("[%s]") or p_first == "\194\160" or p_first == "\226\128\175"
		local starts_with_punct = p_first:match("[.,;:%?!'\"%)%]]")
		
		if ends_with_space and starts_with_space then
			to_type = to_type:gsub("^[%s\194\160\226\128\175]+", "")
		elseif not ends_with_space and not starts_with_space and not starts_with_punct then
			to_type = " " .. to_type
		end
	end

	Logger.info(LOG, "Prediction overlap resolved successfully.")
	return deletes, to_type
end





-- =================================
-- =================================
-- ======= 4/ Window Ignorer =======
-- =================================
-- =================================

local _ignored_win_cache_time  = 0
local _ignored_win_cache_value = false

--- Determines if the currently active window should be ignored based on titles or regex patterns.
--- @param ignored_titles table A hash map of exact window titles to ignore.
--- @param ignored_patterns table A list of regex patterns matching window titles to ignore.
--- @return boolean True if the window is ignored, false otherwise.
function M.is_ignored_window(ignored_titles, ignored_patterns)
	local now = hs.timer.secondsSinceEpoch()
	-- Cache evaluation for half a second to prevent heavy OS querying
	if now - _ignored_win_cache_time < 0.5 then return _ignored_win_cache_value end
	_ignored_win_cache_time = now
	
	_ignored_win_cache_value = false
	
	local app = hs.application.frontmostApplication()
	if not app then return false end

	local ok, win = pcall(function() return app:focusedWindow() end)
	if not ok or not win then return false end

	local ok_title, title = pcall(function() return win:title() end)
	if not ok_title or type(title) ~= "string" then return false end

	-- Check exact titles
	if type(ignored_titles) == "table" and ignored_titles[title] then
		_ignored_win_cache_value = true
		return true
	end

	-- Check regex patterns
	if type(ignored_patterns) == "table" then
		for _, pat in ipairs(ignored_patterns) do
			if type(pat) == "string" and title:match(pat) then
				_ignored_win_cache_value = true
				return true
			end
		end
	end

	return false
end

return M
