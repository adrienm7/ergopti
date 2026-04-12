--- modules/llm/parser.lua

--- ==============================================================================
--- MODULE: LLM Output Parser
--- DESCRIPTION:
--- Strips conversational fillers and applies a 2-tier semantic diffing
--- algorithm to align LLM predictions perfectly with the user's active buffer.
---
--- FEATURES & RATIONALE:
--- 1. NFD Normalization: Intercepts decomposed macOS characters (e + ´).
--- 2. Decoupled Pipeline: Separates physical typing ops from UI visual chunks.
--- 3. Visual Filtering: Hides useless gray anchors if no visible correction occurred.
--- ==============================================================================

local M = {}

local utils  = require("lib.text_utils")
local Logger = require("lib.logger")
local LOG    = "llm.parser"





-- =====================================
-- =====================================
-- ======= 1/ Cleanup & Extraction =======
-- =====================================
-- =====================================

--- Normalizes macOS NFD characters (decomposed) into standard NFC characters.
--- @param s string The input string from the macOS buffer.
--- @return string The normalized string.
local function normalize_nfd(s)
	if type(s) ~= "string" then return s end
	local nfd_map = {
		["a\204\128"] = "à", ["a\204\130"] = "â", ["a\204\136"] = "ä",
		["e\204\128"] = "è", ["e\204\129"] = "é", ["e\204\130"] = "ê", ["e\204\136"] = "ë",
		["i\204\130"] = "î", ["i\204\136"] = "ï",
		["o\204\130"] = "ô", ["o\204\136"] = "ö",
		["u\204\128"] = "ù", ["u\204\130"] = "û", ["u\204\136"] = "ü",
		["c\204\167"] = "ç",
		["A\204\128"] = "À", ["A\204\130"] = "Â", ["A\204\136"] = "Ä",
		["E\204\128"] = "È", ["E\204\129"] = "É", ["E\204\130"] = "Ê", ["E\204\136"] = "Ë",
		["I\204\130"] = "Î", ["I\204\136"] = "Ï",
		["O\204\130"] = "Ô", ["O\204\136"] = "Ö",
		["U\204\128"] = "Ù", ["U\204\130"] = "Û", ["U\204\136"] = "Ü",
		["C\204\167"] = "Ç"
	}
	for nfd, nfc in pairs(nfd_map) do
		s = s:gsub(nfd, nfc)
	end
	return s
end

--- Enforces strict maximum word limits by truncating excess.
--- @param text string The predicted next words.
--- @param max_w number Maximum allowed words (0 for unlimited).
--- @return string The processed string.
local function enforce_word_limits(text, max_w)
	if type(text) ~= "string" or text == "" then return "" end
	if max_w <= 0 then return text:gsub("%s+$", "") end
	
	local count = 0
	local rebuilt = ""
	for w, s in text:gmatch("(%S+)(%s*)") do
		count = count + 1
		if count > max_w then break end
		rebuilt = rebuilt .. w
		if count < max_w then rebuilt = rebuilt .. s end
	end
	return rebuilt:gsub("%s+$", "")
end

--- Strips conversational filler and markdown from the model’s raw text.
--- @param text string The raw output from the LLM.
--- @return string The cleaned text.
local function clean_model_output(text)
	if type(text) ~= "string" then return "" end
	
	text = utils.unescape_text(text)
	text = text:gsub("%*%*", ""):gsub("`", ""):gsub("\"", "")
	text = text:gsub("<[^>]->", "")
	
	text = text:gsub("^Voici la suite%s*:?%s*", "")
	text = text:gsub("^Je propose%s*:?%s*", "")
	text = text:gsub("^[Ss]uite%s+[Ff]inale%s*[:%.%-]*%s*", "")
	text = text:gsub("</body>%s*</html>", "")
	text = text:gsub("^[Ss][Uu][Ii][Tt][Ee]%s*:%s*", "")
	
	text = text:gsub("%[[Tt][Aa][Ii][Ll]_[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%]", "TAIL_CORRECTED:")
	text = text:gsub("%[[Nn][Ee][Xx][Tt]_[Ww][Oo][Rr][Dd][Ss]%]", "NEXT_WORDS:")
	text = text:gsub("[Tt][Aa][Ii][Ll]_[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:", "TAIL_CORRECTED:")
	text = text:gsub("[Nn][Ee][Xx][Tt]_[Ww][Oo][Rr][Dd][Ss]%s*:", "NEXT_WORDS:")
	
	return text
end

--- Removes XML-like thinking tags from the model’s response to isolate the final answer.
--- @param text string The raw response containing potential thinking blocks.
--- @return string The response without thinking tags.
function M.strip_thinking(text)
	if type(text) ~= "string" then return "" end
	text = text:gsub("<think>.-</think>%s*", "")
	text = text:gsub("</think>%s*", "")
	return text
end

--- Splits batch output into individual prediction blocks based on separators.
--- @param raw string The concatenated batch output.
--- @return table An array of string blocks.
function M.split_blocks(raw)
	local blocks = {}
	for block in (raw .. "==="):gmatch("(.-)===") do
		local clean = block:gsub("^%s+", ""):gsub("%s+$", "")
		if clean ~= "" then table.insert(blocks, clean) end
	end
	if #blocks == 0 then table.insert(blocks, raw) end
	return blocks
end





-- =======================================
-- =======================================
-- ======= 2/ Two-Tier Smart Diff ========
-- =======================================
-- =======================================

--- Extracts UTF-8 characters securely into an array.
--- @param s string The input string.
--- @return table Array of characters.
local function get_chars(s)
	local chars = {}
	for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(chars, c)
	end
	return chars
end

--- Tokenizes a string into semantic elements (words, spaces, punctuation).
--- Keeps typographic apostrophes bound to the word.
--- @param s string The string to tokenize.
--- @return table Array of tokens.
local function tokenize(s)
	local tokens = {}
	local current = ""
	local current_type = 0 -- 1=word, 2=space, 3=punctuation

	for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local t = 0
		if c:match("%s") or c == "\194\160" or c == "\226\128\175" then
			t = 2
		elseif c:match("[%w']") or c == "’" or c:byte() >= 128 then
			t = 1
		else
			t = 3
		end

		if t == 3 then
			if current ~= "" then table.insert(tokens, current) end
			table.insert(tokens, c)
			current = ""
			current_type = 0
		elseif t == current_type then
			current = current .. c
		else
			if current ~= "" then table.insert(tokens, current) end
			current = c
			current_type = t
		end
	end
	if current ~= "" then table.insert(tokens, current) end
	return tokens
end

--- Calculates the cost of substituting two semantic tokens.
--- Implements a strict similarity threshold to avoid scrambling unrelated words.
--- @param t1 string The original token.
--- @param t2 string The target token.
--- @return number The substitution cost.
local function token_sub_cost(t1, t2)
	if t1 == t2 then return 0 end
	
	local type1 = (t1:match("%s") and 2) or (t1:match("[%w’']") and 1) or 3
	local type2 = (t2:match("%s") and 2) or (t2:match("[%w’']") and 1) or 3
	
	if type1 ~= type2 then return 1000 end
	
	local c1 = get_chars(t1)
	local c2 = get_chars(t2)
	
	local matrix = {}
	for i = 0, #c1 do matrix[i] = {[0] = i} end
	for j = 0, #c2 do matrix[0][j] = j end
	
	for i = 1, #c1 do
		for j = 1, #c2 do
			local cost = (c1[i] == c2[j] and 0 or 1)
			matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
		end
	end
	
	local dist = matrix[#c1][#c2]
	local max_len = math.max(#c1, #c2)
	local threshold = math.max(1, max_len * 0.5)
	
	if dist > threshold then return 1000 end
	return dist
end

--- Performs a precise character-level diff strictly bounded within a single word.
--- Uses a prefix/suffix isolation method to generate clean typo visualisations.
--- @param w1 string The original word.
--- @param w2 string The corrected word.
--- @return table Array of styled chunks.
local function intra_word_diff(w1, w2)
	local c1 = get_chars(w1)
	local c2 = get_chars(w2)
	
	local p_len = 0
	while p_len < #c1 and p_len < #c2 and c1[p_len+1] == c2[p_len+1] do
		p_len = p_len + 1
	end
	
	local s_len = 0
	while s_len < (#c1 - p_len) and s_len < (#c2 - p_len) and c1[#c1 - s_len] == c2[#c2 - s_len] do
		s_len = s_len + 1
	end
	
	local prefix = table.concat(c2, "", 1, p_len)
	local mid    = table.concat(c2, "", p_len + 1, #c2 - s_len)
	local suffix = table.concat(c2, "", #c2 - s_len + 1, #c2)
	
	local chunks = {}
	if prefix ~= "" then table.insert(chunks, {type="equal", text=prefix}) end
	
	-- Force the whole word to green if it's a pure deletion inside a word (e.g. histoires -> histoire)
	-- This prevents silent/invisible corrections in the UI.
	if mid == "" and w1 ~= w2 then
		return {{type="insert", text=w2}}
	end
	
	if mid ~= "" then table.insert(chunks, {type="insert", text=mid}) end
	if suffix ~= "" then table.insert(chunks, {type="equal", text=suffix}) end
	
	return chunks
end

--- Computes a smart semantic diff preventing cross-word character scrambling.
--- Also cleanly isolates trailing insertions to feed the 'next words' (orange) UI.
--- @param s1 string The original text context.
--- @param s2 string The corrected prediction text.
--- @return table, string, table The chunks, trailing new words, and raw visual ops.
function M.smart_diff(s1, s2)
	local tokens1 = tokenize(s1)
	local tokens2 = tokenize(s2)
	local len1, len2 = #tokens1, #tokens2

	local d = {}
	for i = 0, len1 do d[i] = {[0] = i * 2} end
	for j = 0, len2 do d[0][j] = j * 2 end

	for i = 1, len1 do
		for j = 1, len2 do
			local cost_del = d[i-1][j] + #get_chars(tokens1[i])
			local cost_ins = d[i][j-1] + #get_chars(tokens2[j])
			local cost_sub = d[i-1][j-1] + token_sub_cost(tokens1[i], tokens2[j])
			d[i][j] = math.min(cost_del, cost_ins, cost_sub)
		end
	end

	local i, j = len1, len2
	local ops = {}
	while i > 0 or j > 0 do
		if i > 0 and j > 0 and tokens1[i] == tokens2[j] then
			table.insert(ops, 1, {type="equal", t1=tokens1[i], t2=tokens2[j]})
			i, j = i - 1, j - 1
		else
			local cost_del = i > 0 and (d[i-1][j] + #get_chars(tokens1[i])) or math.huge
			local cost_ins = j > 0 and (d[i][j-1] + #get_chars(tokens2[j])) or math.huge
			local cost_sub = (i > 0 and j > 0) and (d[i-1][j-1] + token_sub_cost(tokens1[i], tokens2[j])) or math.huge

			local min_cost = math.min(cost_del, cost_ins, cost_sub)

			if min_cost == cost_sub then
				table.insert(ops, 1, {type="sub", t1=tokens1[i], t2=tokens2[j]})
				i, j = i - 1, j - 1
			elseif min_cost == cost_del then
				table.insert(ops, 1, {type="del", t1=tokens1[i]})
				i = i - 1
			else
				table.insert(ops, 1, {type="ins", t2=tokens2[j]})
				j = j - 1
			end
		end
	end

	-- Isolate strictly trailing insertions into display_nw (orange section).
	-- Stop extracting if the insertion acts as a replacement for a deleted word.
	local trailing_nw = ""
	local last_idx = #ops
	while last_idx > 0 do
		if ops[last_idx].type == "ins" then
			if last_idx > 1 and ops[last_idx-1].type == "del" then
				break
			end
			last_idx = last_idx - 1
		else
			break
		end
	end
	
	for k = last_idx + 1, #ops do
		trailing_nw = trailing_nw .. ops[k].t2
	end
	
	local visual_ops = {}
	for k = 1, last_idx do
		table.insert(visual_ops, ops[k])
	end

	-- Transform remaining operations into UI chunks
	local raw_chunks = {}
	for _, op in ipairs(visual_ops) do
		if op.type == "equal" then
			table.insert(raw_chunks, {type="equal", text=op.t2})
		elseif op.type == "ins" then
			table.insert(raw_chunks, {type="insert", text=op.t2})
		elseif op.type == "sub" then
			local w1, w2 = op.t1, op.t2
			local is_word1 = w1:match("[%w’']") or w1:byte() >= 128
			local is_word2 = w2:match("[%w’']") or w2:byte() >= 128
			
			if is_word1 and is_word2 then
				local sub_chunks = intra_word_diff(w1, w2)
				for _, sc in ipairs(sub_chunks) do
					table.insert(raw_chunks, sc)
				end
			else
				table.insert(raw_chunks, {type="insert", text=w2})
			end
		end
	end

	-- Merge contiguous chunks of the same type
	local merged = {}
	for _, c in ipairs(raw_chunks) do
		local last = merged[#merged]
		if last and last.type == c.type then
			last.text = last.text .. c.text
		else
			table.insert(merged, {type=c.type, text=c.text})
		end
	end

	return merged, trailing_nw, visual_ops
end





-- ========================================
-- ========================================
-- ======= 3/ Core Processing Logic =======
-- ========================================
-- ========================================

--- Parses explicit prompt tags to determine insertions and deletions securely.
--- @param full_text string The full user context provided to the LLM.
--- @param tail_text string The current end of the user’s input.
--- @param block string The raw block of text generated by the model.
--- @return table|nil A table containing prediction data or nil if invalid.
function M.process_prediction(full_text, tail_text, block)
	Logger.debug(LOG, "Parsing model output block…")
	
	local Core = require("modules.llm.init")
	local min_w = tonumber(hs.settings.get("llm_min_words")) or Core.DEFAULT_STATE.llm_min_words
	local max_w = tonumber(hs.settings.get("llm_max_words")) or Core.DEFAULT_STATE.llm_max_words
	if max_w > 0 and max_w < min_w then max_w = min_w end
	
	-- Normalize NFD (macOS decomposed characters) and apostrophes before any diffing
	full_text = normalize_nfd(type(full_text) == "string" and full_text or ""):gsub("'", "’")
	tail_text = normalize_nfd(type(tail_text) == "string" and tail_text or ""):gsub("'", "’")
	block     = normalize_nfd(type(block) == "string" and block or ""):gsub("'", "’")
	
	block = clean_model_output(block)
	
	local is_advanced = block:find("TAIL_CORRECTED") or block:find("NEXT_WORDS")
	
	if is_advanced then
		local tc = block:match("TAIL_CORRECTED%s*:%s*(.-)[\r\n]+") or block:match("TAIL_CORRECTED%s*:%s*(.-)$") or ""
		local nw = block:match("NEXT_WORDS%s*:%s*(.-)[\r\n]+") or block:match("NEXT_WORDS%s*:%s*(.-)$") or ""

		local function trim(s)
			return s:match("^%s*(.-)%s*$") or ""
		end

		tc = trim(tc:gsub("%s*%]$", ""):gsub("^\"", ""):gsub("\"$", ""))
		nw = trim(nw:gsub("%s*%]$", ""):gsub("^\"", ""):gsub("\"$", ""))
		
		-- Enforce typography normalisation on model predictions to match input state
		tc = tc:gsub("'", "’")
		nw = nw:gsub("'", "’")
		
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")

		-- Apply strict maximum word limit before diffing
		nw = enforce_word_limits(nw, max_w)
		if nw == "" then return nil end

		if tc == "" and nw ~= "" then
			tc = trim((tail_text or ""):gsub("^\"", ""):gsub("\"$", ""))
		end

		if tc == "" and nw == "" then return nil end

		local normalized_full = (full_text or "")
		local tc_norm = tc
		
		-- Restore trailing spaces entered by the user
		local tail_trailing_space = normalized_full:match("([%s\194\160\226\128\175]+)$")
		if tail_trailing_space and not tc_norm:match("[%s\194\160\226\128\175]$") then
			tc_norm = tc_norm .. tail_trailing_space
		end

		-- Smart spacing merge to prevent LLM cutting mid-word without space
		local last_char = utils.utf8_sub(tc_norm, -1)
		local first_char = utils.utf8_sub(nw, 1, 1)
		local needs_space = not (last_char:match("[%s'’%-]") or last_char == "\194\160" or last_char == "\226\128\175" or first_char:match("[%s.,;)%}%%%]]") or nw == "")
		
		local nw_norm = nw
		if needs_space then 
			nw_norm = " " .. nw_norm 
		end

		-- Build the absolute complete intended string from the LLM
		local full_llm = tc_norm .. nw_norm
		
		-- STRICT LIMITER: Prevent massive backwards deletion.
		-- We restrict the search window to max 2 words ago or 30 chars.
		local safe_search_start = #normalized_full
		local space_count = 0
		for i = #normalized_full, 1, -1 do
			local c = normalized_full:sub(i, i)
			if c == " " or c == "\n" or c == "\t" or c == "\194\160" or c == "\226\128\175" then
				space_count = space_count + 1
				if space_count == 2 then
					safe_search_start = i
					break
				end
			end
		end
		safe_search_start = math.max(safe_search_start, #normalized_full - 30)
		safe_search_start = math.max(1, safe_search_start)

		-- Sliding window alignment safely bounded
		local search_start = safe_search_start
		local best_c_len = -1
		local best_suffix = ""
		
		for i = search_start, #normalized_full do
			local b = normalized_full:byte(i)
			if b < 0x80 or b >= 0xC0 then
				local suffix = normalized_full:sub(i)
				local c_len = utils.get_common_prefix_utf8(suffix, full_llm)
				if c_len > best_c_len then
					best_c_len = c_len
					best_suffix = suffix
				end
			end
		end
		
		if best_c_len < 2 and #full_llm > 5 then
			best_suffix = (tail_text or "")
			best_c_len = utils.get_common_prefix_utf8(best_suffix, full_llm)
		end

		local tail_len = utils.utf8_len(tail_text)
		if best_c_len < tail_len * 0.4 and utils.utf8_len(tc_norm) < tail_len * 0.4 then return nil end

		-- Physical exact limits for OS injection (Decoupled from visual rendering)
		local true_deletes = utils.utf8_len(best_suffix) - best_c_len
		local true_to_type = utils.utf8_sub(full_llm, best_c_len + 1)

		if true_to_type:gsub("[%s%.…]", "") == "" then return nil end

		-- Guarantee the final text injected has at least the minimum required words
		local final_count = 0
		for _ in true_to_type:gmatch("%S+") do final_count = final_count + 1 end
		if final_count < min_w then return nil end

		local has_corr = false
		local chunks = {}
		local display_nw = ""
		local disable_bold = false

		-- If true_deletes > 0, the LLM actively modified or removed a user character
		if true_deletes > 0 then
			has_corr = true
			
			local prefix = utils.utf8_sub(full_llm, 1, best_c_len)
			local word_start_char = 1
			
			-- Look backwards to find the start of the corrected word for visual anchoring
			for i = utils.utf8_len(prefix), 1, -1 do
				local c = utils.utf8_sub(prefix, i, i)
				if c == " " or c == "\n" or c == "\t" or c == "\194\160" or c == "\226\128\175" then
					word_start_char = i + 1
					break
				end
			end

			local active_start_char = word_start_char
			local display_orig = utils.utf8_sub(best_suffix, active_start_char)
			local display_corr = utils.utf8_sub(full_llm, active_start_char)
			
			-- Deploy 2-tier smart semantic diff
			local visual_ops
			chunks, display_nw, visual_ops = M.smart_diff(display_orig, display_corr)

			-- Intelligent UI Filtering: If the only modification is a space,
			-- hide the gray anchor entirely so the user only sees the orange NW.
			local has_visible_correction = false
			for _, op in ipairs(visual_ops) do
				if op.type == "sub" then
					has_visible_correction = true
				elseif op.type == "del" and op.t1 and op.t1:match("%S") then
					has_visible_correction = true
				elseif op.type == "ins" and op.t2 and op.t2:match("%S") then
					has_visible_correction = true
				end
			end

			local has_green = false
			for _, c in ipairs(chunks) do
				if c.type == "insert" then has_green = true; break end
			end

			if not has_visible_correction then
				chunks = {} -- Clear useless gray anchors
			elseif has_visible_correction and not has_green then
				-- If a word was deleted but there is no green insertion to show it,
				-- force all chunks to green so the user is visually alerted.
				for _, c in ipairs(chunks) do
					c.type = "insert"
				end
			end

			-- Check if green (insert) directly touches orange (nw). If so, disable bold styling.
			if #chunks > 0 and chunks[#chunks].type == "insert" and display_nw:match("%S") ~= nil then
				disable_bold = true
			end

		else
			has_corr = false
			chunks = {}
			display_nw = true_to_type
		end

		-- Smart spacing fallback for Advanced Mode to ensure perfect connections
		if true_deletes == 0 and true_to_type ~= "" and tail_text ~= "" then
			local t_last = utils.utf8_sub(tail_text, -1)
			local is_space = t_last:match("[%s]") or t_last == "\194\160" or t_last == "\226\128\175"
			local is_apos  = t_last:match("['’]")
			local type_start = utils.utf8_sub(true_to_type, 1, 1)
			
			if not is_space and not is_apos and not type_start:match("[%s.,;?!]") then
				true_to_type = " " .. true_to_type
				if display_nw ~= "" and not display_nw:match("^%s") then
					display_nw = " " .. display_nw
				end
			elseif is_space and type_start:match("^%s") then
				-- Prevent double spaces if both tail_text and to_type have a space
				true_to_type = true_to_type:gsub("^%s+", "")
				display_nw = display_nw:gsub("^%s+", "")
			end
		end

		return { 
			deletes = true_deletes, 
			to_type = true_to_type, 
			nw = display_nw, 
			has_corrections = has_corr, 
			chunks = chunks,
			disable_bold = disable_bold
		}
		
	else
		-- Basic / Raw Mode: Grab only the first line to truncate chatty paragraphs
		local nw = block:gsub("^%s+", ""):gsub("%s+$", "")
		nw = nw:match("([^\n\r]+)") or nw
		nw = nw:gsub("^%[?[Nn][Ee][Xx][Tt]%]?%s*:?%s*", "")
		nw = nw:gsub("^[Ss][Uu][Ii][Tt][Ee]%s*:%s*", "")
		nw = nw:gsub("^[Ss]uite%s+[Ff]inale%s*[:%.%-]*%s*", "")
		nw = nw:gsub("^[-•*]+%s*", "")
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")
		nw = nw:gsub("'", "’")
		
		if nw:find("www%.") or nw:find("http") or nw:find("</") then return nil end
		
		-- Robust overlap mitigation using word-by-word comparison for basic models
		local full_words = {}
		for w in (full_text or ""):gmatch("%S+") do table.insert(full_words, w) end
		
		local nw_words = {}
		for w in nw:gmatch("%S+") do table.insert(nw_words, w) end
		
		local start_idx = math.max(1, #full_words - 20)
		for i = start_idx, #full_words do
			local buf_suffix_count = #full_words - i + 1
			if buf_suffix_count <= #nw_words then
				local match = true
				for j = 1, buf_suffix_count do
					local bw = full_words[i + j - 1]:lower():gsub("[%p%c]", "")
					local pw = nw_words[j]:lower():gsub("[%p%c]", "")
					if bw ~= pw or bw == "" then
						match = false
						break
					end
				end
				
				if match then
					local remaining = {}
					for j = buf_suffix_count + 1, #nw_words do
						table.insert(remaining, nw_words[j])
					end
					nw = table.concat(remaining, " ")
					break
				end
			end
		end
		
		nw = nw:gsub("%s*%]$", ""):gsub("%s+$", "")

		-- Apply strict max word limits before diffing
		nw = enforce_word_limits(nw, max_w)
		if nw == "" then return nil end

		local to_type = nw
		local deletes = 0
		
		-- Smart spacing taking UTF-8 apostrophes and raw bytes into account for basic mode
		if to_type ~= "" and tail_text ~= "" then
			local t_last = utils.utf8_sub(tail_text, -1)
			local is_space = t_last:match("[%s]") or t_last == "\194\160" or t_last == "\226\128\175"
			local is_apos  = t_last:match("['’]")
			local type_start = utils.utf8_sub(to_type, 1, 1)
			
			if not is_space and not is_apos and not type_start:match("[%s.,;?!]") then
				to_type = " " .. to_type
				nw = " " .. nw
			elseif is_space and type_start:match("^%s") then
				-- Prevent double spaces if both tail_text and to_type have a space
				to_type = to_type:gsub("^%s+", "")
				nw = nw:gsub("^%s+", "")
			end
		end

		if to_type:gsub("[%s%.…]", "") == "" then return nil end
		
		-- Guarantee the final text injected has at least the minimum required words
		local final_count = 0
		for _ in to_type:gmatch("%S+") do final_count = final_count + 1 end
		if final_count < min_w then return nil end
		
		Logger.info(LOG, "Fallback text parsed successfully.")
		return { deletes = deletes, to_type = to_type, nw = nw, has_corrections = false, chunks = {}, disable_bold = false }
	end
end

return M
