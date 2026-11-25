--- _shared/shortcuts/engine/text_target.lua

--- ==============================================================================
--- MODULE: Text Targets — Shared Lua Implementation
--- DESCRIPTION:
--- Finds a text target (« Autoriser une fois », « Allow once »…) among the
--- words a text recognition returned, so the auto-clicker and the user
--- workflows click a button by its caption whatever its theme or colours. The
--- macOS and Linux drivers match through this module; the Windows driver runs
--- a twin pinned by the same corpus.
---
--- FEATURES & RATIONALE:
--- 1. Normalised comparison: lower case, accents removed and a few ligatures
---    spelled out (_shared/core/text/data/text_fold.json), punctuation and
---    every space read as one space, so « Autoriser  une fois… » is
---    « autoriser une fois ».
--- 2. Tolerance: a target admits an edit distance (Levenshtein, counted in
---    characters, not bytes) up to its max_distance, for the letter an OCR
---    misreads.
--- 3. Word windows on one line: a variant of k words is compared with every run
---    of k - 1, k and k + 1 consecutive words of a line, since an OCR may split
---    a word or glue two. The hit is the union of the run's boxes.
--- 4. Deterministic choice: the smallest distance, then the run whose word
---    count is closest to the variant's, then reading order.
--- 5. Lua 5.1 syntax (LuaJIT on Linux): UTF-8 is walked byte by byte, no utf8
---    library and no integer division.
---
--- Pinned by _shared/tests/corpus/keep_awake/text_target_vectors.json.
--- ==============================================================================

local M = {}

local _fold = nil




-- =============================================
-- =============================================
-- ======= 1/ Normalisation ====================
-- =============================================
-- =============================================

--- Binds the folding table.
--- @param fold table character -> folded text, as text_fold.json holds it.
function M.set_fold(fold)
	assert(type(fold) == "table", "the folding table is a map")
	_fold = fold
end

--- Splits a UTF-8 string into characters; a malformed byte stands alone.
--- @param text string
--- @return table characters
function M.characters(text)
	local out, i, n = {}, 1, #text
	while i <= n do
		local b = text:byte(i)
		local size = 1
		if b >= 0xF0 and b <= 0xF4 then size = 4
		elseif b >= 0xE0 then size = 3
		elseif b >= 0xC2 and b < 0xE0 then size = 2 end
		if i + size - 1 > n then size = 1 end
		for k = i + 1, i + size - 1 do
			local c = text:byte(k)
			if c < 0x80 or c > 0xBF then size = 1; break end
		end
		out[#out + 1] = text:sub(i, i + size - 1)
		i = i + size
	end
	return out
end

-- Non-ASCII characters read as a separator: spaces, quotes, dashes, ellipsis.
local SEPARATORS = {
	["\194\160"] = true, ["\226\128\175"] = true, ["\226\128\137"] = true, ["\226\128\166"] = true,
	["\194\171"] = true, ["\194\187"] = true, ["\226\128\152"] = true, ["\226\128\153"] = true,
	["\226\128\156"] = true, ["\226\128\157"] = true, ["\226\128\147"] = true, ["\226\128\148"] = true,
	["\226\128\139"] = true, ["\226\128\140"] = true, ["\226\128\141"] = true, ["\239\187\191"] = true,
}

--- Normalises a text for comparison.
--- @param text string UTF-8.
--- @return string normalised Lower case, no accents, single spaces, trimmed.
function M.normalize(text)
	assert(type(text) == "string", "a text target is a string")
	assert(_fold, "the folding table is not bound (text_target.set_fold)")
	local out = {}
	for _, ch in ipairs(M.characters(text)) do
		local b = ch:byte(1)
		if #ch == 1 then
			if (b >= 48 and b <= 57) or (b >= 97 and b <= 122) then out[#out + 1] = ch
			elseif b >= 65 and b <= 90 then out[#out + 1] = string.char(b + 32)
			else out[#out + 1] = " " end
		elseif SEPARATORS[ch] then
			out[#out + 1] = " "
		else
			out[#out + 1] = _fold[ch] or ch
		end
	end
	local joined = table.concat(out):gsub("%s+", " ")
	return (joined:gsub("^ ", ""):gsub(" $", ""))
end

--- The edit distance between two normalised texts, in characters.
--- @param a string
--- @param b string
--- @return integer distance
function M.distance(a, b)
	local ca, cb = M.characters(a), M.characters(b)
	local previous = {}
	for j = 0, #cb do previous[j] = j end
	for i = 1, #ca do
		local current = { [0] = i }
		for j = 1, #cb do
			local cost = (ca[i] == cb[j]) and 0 or 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#cb]
end




-- =============================================
-- =============================================
-- ======= 2/ Matching =========================
-- =============================================
-- =============================================

--- Groups words into lines, in the order the recognition returned them.
local function lines_of(words)
	local lines, by_id = {}, {}
	for index, word in ipairs(words) do
		local normalised = M.normalize(word.text)
		if normalised ~= "" then
			local line = by_id[word.line]
			if not line then
				line = { words = {} }
				by_id[word.line] = line
				lines[#lines + 1] = line
			end
			line.words[#line.words + 1] = { word = word, text = normalised, order = index }
		end
	end
	return lines
end

--- The union box of a run of words.
local function union(run)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, entry in ipairs(run) do
		local w = entry.word
		x0, y0 = math.min(x0, w.x), math.min(y0, w.y)
		x1, y1 = math.max(x1, w.x + w.width), math.max(y1, w.y + w.height)
	end
	return x0, y0, x1 - x0, y1 - y0
end

local function word_count(text)
	local n = 0
	for _ in text:gmatch("%S+") do n = n + 1 end
	return n
end

--- Finds the best hit of one target among recognised words.
--- @param words table { text, x, y, width, height, line } as the OCR returns them.
--- @param target table { id, variants = { string… }, max_distance = integer }
--- @return table|nil hit { id, variant, text, x, y, width, height, distance }
function M.find(words, target)
	assert(type(words) == "table", "the recognised words are a list")
	assert(type(target) == "table" and type(target.variants) == "table" and #target.variants >= 1,
		"a text target needs at least one variant")
	local max_distance = target.max_distance
	assert(type(max_distance) == "number" and max_distance >= 0 and max_distance % 1 == 0,
		"a text target's max_distance is a non-negative integer")
	local best
	local lines = lines_of(words)
	for _, variant in ipairs(target.variants) do
		local wanted = M.normalize(variant)
		local k = word_count(wanted)
		if k > 0 then
			for _, line in ipairs(lines) do
				for size = math.max(1, k - 1), k + 1 do
					for start = 1, #line.words - size + 1 do
						local run, parts = {}, {}
						for i = start, start + size - 1 do
							run[#run + 1] = line.words[i]
							parts[#parts + 1] = line.words[i].text
						end
						local text = table.concat(parts, " ")
						local distance = M.distance(text, wanted)
						if distance <= max_distance then
							local gap, order = math.abs(size - k), run[1].order
							if not best or distance < best.distance
								or (distance == best.distance and (gap < best.gap
									or (gap == best.gap and order < best.order))) then
								local x, y, w, h = union(run)
								best = { id = target.id, variant = variant, text = text, x = x, y = y,
									width = w, height = h, distance = distance, gap = gap, order = order }
							end
						end
					end
				end
			end
		end
	end
	if best then best.gap, best.order = nil, nil end
	return best
end

return M
