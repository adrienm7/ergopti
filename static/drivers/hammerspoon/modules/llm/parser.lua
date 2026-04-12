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
--- 3. Strict NW Extraction: Guarantees invented words are always orange.
--- ==============================================================================

local M = {}

local utils  = require("lib.text_utils")
local Logger = require("lib.logger")
local LOG    = "llm.parser"





-- =======================================
-- =======================================
-- ======= 1/ Cleanup & Extraction =======
-- =======================================
-- =======================================

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





-- ======================================
-- ======================================
-- ======= 2/ Two-Tier Smart Diff =======
-- ======================================
-- ======================================

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
	if mid ~= "" then table.insert(chunks, {type="insert", text=mid}) end
	if suffix ~= "" then table.insert(chunks, {type="equal", text=suffix}) end
	
	return chunks
end

--- Computes a semantic diff ops array between origin and correction.
--- @param orig string The original text.
--- @param corr string The corrected text.
--- @return table Raw diff operations.
local function token_diff_ops(orig, corr)
	local tokens1 = tokenize(orig)
	local tokens2 = tokenize(corr)
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
	return ops
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
	
	-- Strict NFD normalization and typography unification to avoid false positive diffs
	full_text = normalize_nfd(type(full_text) == "string" and full_text or ""):gsub("'", "’")
	tail_text = normalize_nfd(type(tail_text) == "string" and tail_text or ""):gsub("'", "’")
	block     = normalize_nfd(type(block) == "string" and block or ""):gsub("'", "’")
	
	block = clean_model_output(block)
	
	local is_advanced = block:find("TAIL_CORRECTED") or block:find("NEXT_WORDS")
	
	if is_advanced then
		local tc = block:match("TAIL_CORRECTED%s*:%s*(.-)[\r\n]+") or block:match("TAIL_CORRECTED%s*:%s*(.-)$") or ""
		local nw = block:match("NEXT_WORDS%s*:%s*(.-)[\r\n]+") or block:match("NEXT_WORDS%s*:%s*(.-)$") or ""

		local function trim(s) return s:match("^%s*(.-)%s*$") or "" end

		tc = trim(tc:gsub("%s*%]$", ""):gsub("^\"", ""):gsub("\"$", ""))
		nw = trim(nw:gsub("%s*%]$", ""):gsub("^\"", ""):gsub("\"$", ""))
		
		tc = tc:gsub("'", "’")
		nw = nw:gsub("'", "’")
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")

		nw = enforce_word_limits(nw, max_w)
		if nw == "" then return nil end

		if tc == "" and nw ~= "" then
			tc = trim((tail_text or ""):gsub("^\"", ""):gsub("\"$", ""))
		end
		if tc == "" and nw == "" then return nil end

		local normalized_full = (full_text or "")
		local tc_norm = tc
		
		-- Match user's trailing spaces to prevent cutting mid-word
		local tail_trailing_space = normalized_full:match("([%s\194\160\226\128\175]+)$")
		if tail_trailing_space and not tc_norm:match("[%s\194\160\226\128\175]$") then
			tc_norm = tc_norm .. tail_trailing_space
		end

		local last_char = utils.utf8_sub(tc_norm, -1)
		local first_char = utils.utf8_sub(nw, 1, 1)
		local needs_space = not (last_char:match("[%s'’%-]") or last_char == "\194\160" or last_char == "\226\128\175" or first_char:match("[%s.,;)%}%%%]]") or nw == "")
		
		local nw_norm = nw
		if needs_space then nw_norm = " " .. nw_norm end
		
		-- Grab a safe sliding window limit from the user's buffer
		local window_size = math.min(#normalized_full, math.max(60, #tc_norm + 30))
		local orig_context = normalized_full:sub(#normalized_full - window_size + 1)
		
		-- 1. Diff strictly against TAIL_CORRECTED to avoid misaligning new words
		local ops = token_diff_ops(orig_context, tc_norm)

		-- 2. Strip leading context but keep a trace of it for dynamic anchor resolution
		local stripped_ops = {}
		while #ops > 0 and ops[1].type == "del" do 
			table.insert(stripped_ops, table.remove(ops, 1))
		end
		while #ops > 0 and ops[1].type == "ins" and ops[1].t2:match("^%s+$") do 
			table.insert(stripped_ops, table.remove(ops, 1))
		end
		
		-- 3. Append NEXT_WORDS strictly as downstream insertions
		if nw_norm ~= "" then
			local nw_tokens = tokenize(nw_norm)
			for _, t in ipairs(nw_tokens) do
				table.insert(ops, {type="ins", t2=t})
			end
		end

		if #ops == 0 then return nil end

		-- 4. Locate the first actual change in the alignment
		local first_change_idx = -1
		for i, op in ipairs(ops) do
			if op.type ~= "equal" then
				first_change_idx = i
				break
			end
		end

		-- If the LLM matched the context perfectly and only appended words
		if first_change_idx == -1 then
			return { deletes = 0, to_type = "", nw = nw_norm, has_corrections = false, chunks = {}, disable_bold = false }
		end

		-- 5. Calculate Physical Injection (strictly optimized)
		local physical_ops = {}
		for i = first_change_idx, #ops do table.insert(physical_ops, ops[i]) end

		local true_deletes = 0
		local true_to_type = ""
		for idx, op in ipairs(physical_ops) do
			-- Optimizes intra-word backspacing so we don't delete shared prefixes
			if idx == 1 and op.type == "sub" then
				local c1 = get_chars(op.t1)
				local c2 = get_chars(op.t2)
				local p_len = 0
				while p_len < #c1 and p_len < #c2 and c1[p_len+1] == c2[p_len+1] do
					p_len = p_len + 1
				end
				true_deletes = true_deletes + (#c1 - p_len)
				true_to_type = true_to_type .. table.concat(c2, "", p_len + 1)
			else
				if op.type == "equal" then
					true_deletes = true_deletes + utils.utf8_len(op.t1)
					true_to_type = true_to_type .. op.t2
				elseif op.type == "del" then
					true_deletes = true_deletes + utils.utf8_len(op.t1)
				elseif op.type == "ins" then
					true_to_type = true_to_type .. op.t2
				elseif op.type == "sub" then
					true_deletes = true_deletes + utils.utf8_len(op.t1)
					true_to_type = true_to_type .. op.t2
				end
			end
		end
		
		-- Safety circuit breaker: Prevent massive unprompted deletions
		local max_allowed_dels = math.max(20, utils.utf8_len(tc_norm) + 10)
		if true_deletes > max_allowed_dels then
			Logger.warning(LOG, string.format("Safety trip: Blocked deletion of %d chars.", true_deletes))
			return nil
		end
		
		if true_to_type:gsub("[%s%.…]", "") == "" then return nil end

		-- 6. Calculate Visual UI (Anchor context + Chunks + Trailing NW)
		local first_op = ops[first_change_idx]
		local needs_anchor = false
		
		if first_op.type == "del" then
			needs_anchor = true
		elseif first_op.type == "sub" then
			local c1 = get_chars(first_op.t1)
			local c2 = get_chars(first_op.t2)
			-- We need the preceding word as an anchor if the modification starts at the very first letter
			if #c1 > 0 and #c2 > 0 and c1[1] ~= c2[1] then
				needs_anchor = true
			end
		elseif first_op.type == "ins" then
			-- Anchor needed if inserting directly attached word characters
			if first_op.t2:match("^[%w’']") then
				needs_anchor = true
			end
		end

		local visual_ops = {}
		
		-- Recover anchor from outside the TC window if it was stripped
		if needs_anchor and first_change_idx == 1 and #stripped_ops > 0 then
			local anchor_parts = {}
			for i = #stripped_ops, 1, -1 do
				table.insert(anchor_parts, 1, stripped_ops[i].t1)
				if stripped_ops[i].t1:match("[%w’']") or stripped_ops[i].t1:byte() >= 128 then
					break
				end
			end
			local anchor_text = table.concat(anchor_parts, "")
			table.insert(visual_ops, {type="equal", t1=anchor_text, t2=anchor_text})
		-- Otherwise, find anchor in the remaining visible ops
		elseif needs_anchor then
			for i = first_change_idx - 1, 1, -1 do
				table.insert(visual_ops, 1, ops[i])
				local is_word = ops[i].t1:match("[%w’']") or ops[i].t1:byte() >= 128
				if is_word then break end
			end
		end

		-- Push physical operations into the visual stack
		for i = first_change_idx, #ops do 
			table.insert(visual_ops, ops[i]) 
		end

		-- Find the boundary where strictly new words (Orange) begin by ignoring trailing DP space matching
		local last_anchor_idx = 0
		for i = #visual_ops, 1, -1 do
			local op = visual_ops[i]
			if op.type ~= "ins" then
				local t1_strip = (op.t1 or ""):gsub("[%s\194\160\226\128\175]", "")
				if t1_strip ~= "" then
					last_anchor_idx = i
					break
				end
			end
		end

		local nw_start_idx = #visual_ops + 1
		if last_anchor_idx > 0 then
			local anchor_op = visual_ops[last_anchor_idx]
			if anchor_op.type == "del" then
				-- Replacement scenario: NW starts after the first inserted word (Green)
				local found_word = false
				for j = last_anchor_idx + 1, #visual_ops do
					if visual_ops[j].type == "ins" and visual_ops[j].t2:match("[%w’']") then
						found_word = true
					elseif found_word and not visual_ops[j].t2:match("[%w’']") then
						nw_start_idx = j
						break
					end
				end
				if not found_word then nw_start_idx = #visual_ops + 1 end
			else
				-- Equal or Sub: NW starts immediately after
				nw_start_idx = last_anchor_idx + 1
			end
		else
			nw_start_idx = 1
		end

		local display_nw = ""
		for k = nw_start_idx, #visual_ops do
			display_nw = display_nw .. visual_ops[k].t2
		end
		
		-- Remove NW operations from visual_ops chunks
		for k = #visual_ops, nw_start_idx, -1 do
			table.remove(visual_ops, k)
		end

		-- Map Visual Ops to UI Chunks
		local raw_chunks = {}
		local has_corr = false
		for _, op in ipairs(visual_ops) do
			if op.type == "equal" then
				table.insert(raw_chunks, {type="equal", text=op.t2})
			elseif op.type == "ins" then
				has_corr = true
				table.insert(raw_chunks, {type="insert", text=op.t2})
			elseif op.type == "sub" then
				has_corr = true
				local w1, w2 = op.t1, op.t2
				local is_word1 = w1:match("[%w’']") or w1:byte() >= 128
				local is_word2 = w2:match("[%w’']") or w2:byte() >= 128
				if is_word1 and is_word2 then
					local sub_chunks = intra_word_diff(w1, w2)
					for _, sc in ipairs(sub_chunks) do table.insert(raw_chunks, sc) end
				else
					table.insert(raw_chunks, {type="insert", text=w2})
				end
			elseif op.type == "del" then
				has_corr = true
			end
		end

		-- Merge contiguous chunks
		local chunks = {}
		for _, c in ipairs(raw_chunks) do
			local last = chunks[#chunks]
			if last and last.type == c.type then
				last.text = last.text .. c.text
			else
				table.insert(chunks, {type=c.type, text=c.text})
			end
		end
		
		-- Clear gray chunks if they are orphaned (no green corrections following them)
		local only_equals = true
		for _, c in ipairs(chunks) do
			if c.type ~= "equal" then
				only_equals = false
				break
			end
		end
		if only_equals then chunks = {} end
		
		-- Precludes double boldness if orange directly follows a green element
		local disable_bold = (#chunks > 0 and chunks[#chunks].type == "insert" and display_nw:match("%S") ~= nil)

		return { 
			deletes = true_deletes, 
			to_type = true_to_type, 
			nw = display_nw, 
			has_corrections = has_corr, 
			chunks = chunks,
			disable_bold = disable_bold
		}
		
	else
		-- Basic / Raw Mode Logic remains untouched
		local nw = block:gsub("^%s+", ""):gsub("%s+$", "")
		nw = nw:match("([^\n\r]+)") or nw
		nw = nw:gsub("^%[?[Nn][Ee][Xx][Tt]%]?%s*:?%s*", "")
		nw = nw:gsub("^[Ss][Uu][Ii][Tt][Ee]%s*:%s*", "")
		nw = nw:gsub("^[Ss]uite%s+[Ff]inale%s*[:%.%-]*%s*", "")
		nw = nw:gsub("^[-•*]+%s*", "")
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")
		nw = nw:gsub("'", "’")
		
		if nw:find("www%.") or nw:find("http") or nw:find("</") then return nil end
		
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
					for j = buf_suffix_count + 1, #nw_words do table.insert(remaining, nw_words[j]) end
					nw = table.concat(remaining, " ")
					break
				end
			end
		end
		
		nw = nw:gsub("%s*%]$", ""):gsub("%s+$", "")
		nw = enforce_word_limits(nw, max_w)
		if nw == "" then return nil end

		local to_type = nw
		local deletes = 0
		
		if to_type ~= "" and tail_text ~= "" then
			local t_last = utils.utf8_sub(tail_text, -1)
			local is_space = t_last:match("[%s]") or t_last == "\194\160" or t_last == "\226\128\175"
			local is_apos  = t_last:match("['’]")
			local type_start = utils.utf8_sub(to_type, 1, 1)
			
			if not is_space and not is_apos and not type_start:match("[%s.,;?!]") then
				to_type = " " .. to_type
				nw = " " .. nw
			elseif is_space and type_start:match("^%s") then
				to_type = to_type:gsub("^%s+", "")
				nw = nw:gsub("^%s+", "")
			end
		end

		if to_type:gsub("[%s%.…]", "") == "" then return nil end
		local final_count = 0
		for _ in to_type:gmatch("%S+") do final_count = final_count + 1 end
		if final_count < min_w then return nil end
		
		Logger.info(LOG, "Fallback text parsed successfully.")
		return { deletes = deletes, to_type = to_type, nw = nw, has_corrections = false, chunks = {}, disable_bold = false }
	end
end

return M
