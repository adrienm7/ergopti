--- _shared/lua/text_utils/init.lua

--- ==============================================================================
--- MODULE: Text Utilities (Shared)
--- DESCRIPTION:
--- Platform-neutral UTF-8 string manipulation, advanced surgical diffing
--- for AI text prediction, and complex case-conversion logic for hotstrings.
--- Shared across all Ergopti+ drivers (Hammerspoon, Linux, and future platforms).
--- Designed to fail safely (using pcall and type checks) even with malformed strings.
---
--- FEATURES & RATIONALE:
--- 1. Platform-neutral: depends only on the Lua 5.3+ standard library (utf8, math,
---    table, string) — no Hammerspoon or OS-specific API is referenced anywhere.
--- 2. Safe UTF-8: every utf8.* call is wrapped in pcall so malformed sequences
---    never surface as unhandled errors, regardless of the host environment.
--- 3. Surgical diff: the Wagner-Fischer engine computes minimal char-level edits
---    so UI overlays can highlight exactly what changed between the user's text
---    and the AI prediction.
--- 4. Case variants: trig_upper/trig_title expose memoised arrays of all possible
---    uppercased triggers, covering multi-valued French punctuation mappings.
--- ==============================================================================

local M = {}





-- =======================================
-- =======================================
-- ======= 1/ UTF-8 Core Utilities =======
-- =======================================
-- =======================================

--- Safely splits a UTF-8 string into a table of individual characters.
--- @param s string The input string.
--- @return table An array of UTF-8 characters.
function M.utf8_chars(s)
	local chars = {}
	if type(s) ~= "string" then return chars end

	pcall(function()
		for _, c in utf8.codes(s) do
			table.insert(chars, utf8.char(c))
		end
	end)

	return chars
end

--- Calculates the length of a common prefix between two UTF-8 strings.
--- Walks both `utf8.codes` iterators in lockstep, so no intermediate character
--- arrays are materialised — critical because this is called per expansion.
--- @param s1 string First string.
--- @param s2 string Second string.
--- @return number The length of the common prefix in characters.
function M.get_common_prefix_utf8(s1, s2)
	if type(s1) ~= "string" or type(s2) ~= "string" then return 0 end
	if s1 == "" or s2 == "" then return 0 end

	-- pcall the whole walk so malformed UTF-8 cannot surface as an error;
	-- worst case we stop early and report whatever prefix was already agreed.
	local ok, count = pcall(function()
		local iter1, inv1, ctrl1 = utf8.codes(s1)
		local iter2, inv2, ctrl2 = utf8.codes(s2)
		local matched = 0
		while true do
			local p1, c1 = iter1(inv1, ctrl1)
			local p2, c2 = iter2(inv2, ctrl2)
			if not p1 or not p2 or c1 ~= c2 then break end
			ctrl1, ctrl2 = p1, p2
			matched = matched + 1
		end
		return matched
	end)
	return (ok and count) and count or 0
end

--- Safely extracts a substring using UTF-8 character indexing.
--- Uses `utf8.offset` for O(|i|+|j|) byte-position lookup instead of building
--- a character array, so long buffers don't pay an allocation per slice.
--- @param s string The input string.
--- @param i number The starting index.
--- @param j number|nil The ending index.
--- @return string The extracted substring.
function M.utf8_sub(s, i, j)
	if type(s) ~= "string" or s == "" then return "" end

	local n = M.utf8_len(s)
	local start_idx = tonumber(i) or 1
	local end_idx   = tonumber(j) or n

	-- Normalise negative indices to positives against the codepoint count.
	if start_idx < 0 then start_idx = n + start_idx + 1 end
	if end_idx < 0 then end_idx = n + end_idx + 1 end

	-- Clamp to bounds (end_idx may legitimately be 0 — empty-range signal — and
	-- must not be snapped up to 1, which would silently return a one-char slice).
	start_idx = math.max(1, math.min(start_idx, n))
	end_idx   = math.max(0, math.min(end_idx, n))

	if start_idx > end_idx then return "" end

	-- Translate codepoint indices to byte offsets. start_byte is the first
	-- byte of codepoint #start_idx; end_byte is the last byte of codepoint
	-- #end_idx, i.e. one byte before the start of codepoint #(end_idx+1).
	local ok_s, start_byte = pcall(utf8.offset, s, start_idx)
	if not ok_s or not start_byte then return "" end

	local end_byte
	if end_idx == n then
		end_byte = #s
	else
		local ok_e, next_byte = pcall(utf8.offset, s, end_idx + 1)
		if not ok_e or not next_byte then return "" end
		end_byte = next_byte - 1
	end

	return s:sub(start_byte, end_byte)
end

--- Safely measures the length of a UTF-8 string.
--- @param s string The input string.
--- @return number The length in characters.
function M.utf8_len(s)
	if type(s) ~= "string" then return 0 end

	-- utf8.len returns nil on invalid UTF-8 sequences, fallback to raw length
	local ok, len = pcall(utf8.len, s)
	return (ok and len) and len or #s
end

--- Checks if a string ends with a specific UTF-8 suffix.
--- @param s string The target string.
--- @param suffix string The suffix to check for.
--- @return boolean True if the string ends with the suffix.
function M.utf8_ends_with(s, suffix)
	if type(s) ~= "string" or type(suffix) ~= "string" then return false end
	if s == "" or suffix == "" then return false end

	local n = M.utf8_len(suffix)
	local ok, start_idx = pcall(utf8.offset, s, -n)

	return (ok and start_idx) and (s:sub(start_idx) == suffix) or false
end

--- Checks if a string contains characters requiring more than 2 bytes.
--- @param s string The input string.
--- @return boolean True if high unicode characters are found.
function M.contains_high_unicode(s)
	if type(s) ~= "string" then return false end

	local found = false
	pcall(function()
		for _, c in utf8.codes(s) do
			if c > 0xFFFF then
				found = true
				break
			end
		end
	end)

	return found
end

--- Safely decodes unicode escape sequences and HTML entities.
--- @param s string The input string.
--- @return string The decoded string.
function M.unescape_text(s)
	if type(s) ~= "string" then return "" end

	-- 1. Decode Unicode escapes: \uXXXX
	s = s:gsub("\\u(%x%x%x%x)", function(hex)
		local code = tonumber(hex, 16)
		if code then
			local ok, char = pcall(utf8.char, code)
			if ok then return char end
		end
		return "\\u" .. hex
	end)

	-- 2. Decode standard backslash escapes
	s = s:gsub("\\'", "'")
	s = s:gsub('\\"', '"')
	s = s:gsub("\\n", "\n")
	s = s:gsub("\\t", "\t")
	s = s:gsub("\\/", "/")

	-- 3. Decode common HTML entities (especially French and typographic ones)
	local entities = {
		["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
		["&quot;"] = '"', ["&apos;"] = "'", ["&#39;"] = "'",
		["&nbsp;"] = " ", ["&#160;"] = " ",
		["&eacute;"] = "é", ["&#233;"] = "é",
		["&egrave;"] = "è", ["&#232;"] = "è",
		["&agrave;"] = "à", ["&#224;"] = "à",
		["&ccedil;"] = "ç", ["&#231;"] = "ç",
		["&ecirc;"] = "ê", ["&#234;"] = "ê",
		["&oe;"] = "œ", ["&#339;"] = "œ",
		["&rsquo;"] = "\u{2019}", ["&#8217;"] = "\u{2019}",
		["&lsquo;"] = "\u{2018}", ["&#8216;"] = "\u{2018}",
		["&laquo;"] = "«", ["&#171;"] = "«",
		["&raquo;"] = "»", ["&#187;"] = "»",
		["&hellip;"] = "…", ["&#8230;"] = "…"
	}
	s = s:gsub("(&[%w#]+;)", function(ent)
		return entities[ent] or ent
	end)

	return s
end





-- =======================================
-- =======================================
-- ======= 2/ Surgical Diff Engine =======
-- =======================================
-- =======================================

--- Computes a Wagner-Fischer edit distance diff to display UI text prediction overlays.
--- @param old_str string The original user text.
--- @param new_str string The predicted text.
--- @return table An array of styled text chunks.
function M.diff_strings(old_str, new_str)
	if type(old_str) ~= "string" or type(new_str) ~= "string" then return {} end

	local t1 = M.utf8_chars(old_str)
	local t2 = M.utf8_chars(new_str)

	-- Find common prefix
	local p = 0
	while p < #t1 and p < #t2 and t1[p+1] == t2[p+1] do
		p = p + 1
	end

	local out = {}
	for i = 1, p do table.insert(out, {char=t1[i], color="grey"}) end

	-- If string 1 is fully contained in string 2
	if p == #t1 then
		for i = p + 1, #t2 do table.insert(out, {char=t2[i], color="orange"}) end
	else
		-- Extract remaining differing segments
		local rem_t1, rem_t2 = {}, {}
		for i = p + 1, #t1 do table.insert(rem_t1, t1[i]) end
		for i = p + 1, #t2 do table.insert(rem_t2, t2[i]) end
		local len1, len2 = #rem_t1, #rem_t2

		-- Wagner-Fischer matrix initialization
		local m = {}
		for i = 0, len1 do
			m[i] = {}
			for j = 0, len2 do
				if i == 0 then m[i][j] = j
				elseif j == 0 then m[i][j] = i
				else m[i][j] = 0 end
			end
		end

		-- Compute distances
		for i = 1, len1 do
			for j = 1, len2 do
				if rem_t1[i] == rem_t2[j] then
					m[i][j] = m[i-1][j-1]
				else
					m[i][j] = math.min(m[i-1][j-1], m[i-1][j], m[i][j-1]) + 1
				end
			end
		end

		-- Backtrack to find operations
		local i, j = len1, len2
		local rev_ops = {}
		while i > 0 or j > 0 do
			if i > 0 and j > 0 and rem_t1[i] == rem_t2[j] then
				table.insert(rev_ops, {type="eq", char=rem_t2[j]})
				i, j = i - 1, j - 1
			elseif i > 0 and j > 0 and m[i][j] == m[i-1][j-1] + 1 then
				table.insert(rev_ops, {type="sub", char=rem_t2[j]})
				i, j = i - 1, j - 1
			elseif j > 0 and (i == 0 or m[i][j] == m[i][j-1] + 1) then
				table.insert(rev_ops, {type="ins", char=rem_t2[j], is_tail=(i == len1)})
				j = j - 1
			elseif i > 0 and (j == 0 or m[i][j] == m[i-1][j] + 1) then
				table.insert(rev_ops, {type="del", char=rem_t1[i]})
				i = i - 1
			end
		end

		-- Apply colors based on operations
		for k = #rev_ops, 1, -1 do
			local op = rev_ops[k]
			if op.type == "eq" then
				table.insert(out, {char=op.char, color="grey"})
			elseif op.type == "sub" then
				table.insert(out, {char=op.char, color="green"})
			elseif op.type == "ins" then
				table.insert(out, {char=op.char, color=op.is_tail and "orange" or "green"})
			elseif op.type == "del" then
				-- Convert preceding grey characters to green if they are adjacent to a deletion
				if #out > 0 and out[#out].color == "grey" and not op.char:match("%s") then
					out[#out].color = "green"
				end
			end
		end
	end

	-- UI Cleaning: Find the first differing character to trim irrelevant context
	local first_diff_idx = 0
	for idx, item in ipairs(out) do
		if item.color ~= "grey" then
			first_diff_idx = idx
			break
		end
	end

	if first_diff_idx > 0 then
		local start_idx = first_diff_idx

		-- Backtrack ONLY to the start of the current word so the first displayed word contains the diff
		while start_idx > 1 do
			local prev_char = out[start_idx - 1].char
			if prev_char:match("[%s'']") then break end
			start_idx = start_idx - 1
		end

		local new_out = {}
		for idx = start_idx, #out do table.insert(new_out, out[idx]) end
		out = new_out
	else
		out = {}
	end

	-- Compile contiguous characters of the same color into chunks
	local chunks, cur_color, cur_str = {}, nil, ""
	for _, item in ipairs(out) do
		if item.color ~= cur_color then
			if cur_color ~= nil then
				local ctype = (cur_color == "grey") and "equal" or "insert"
				table.insert(chunks, {text=cur_str, color=cur_color, type=ctype})
			end
			cur_color = item.color
			cur_str = item.char
		else
			cur_str = cur_str .. item.char
		end
	end

	if cur_str ~= "" then
		local ctype = (cur_color == "grey") and "equal" or "insert"
		table.insert(chunks, {text=cur_str, color=cur_color, type=ctype})
	end

	return chunks
end





-- =========================================
-- =========================================
-- ======= 3/ Case Mapping Constants =======
-- =========================================
-- =========================================

M.UPPER_LETTERS = {
	["à"]="À", ["â"]="Â", ["ä"]="Ä", ["é"]="É", ["è"]="È", ["ê"]="Ê", ["ë"]="Ë",
	["î"]="Î", ["ï"]="Ï", ["ô"]="Ô", ["ö"]="Ö", ["ù"]="Ù", ["û"]="Û", ["ü"]="Ü",
	["ç"]="Ç", ["œ"]="Œ", ["æ"]="Æ"
}

M.LOWER_LETTERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.LOWER_LETTERS[v] = k end

M.UPPER_TRIGGERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.UPPER_TRIGGERS[k] = v end

-- Ergopti-specific French punctuation layer trigger mappings.
--
-- CRITICAL -- the "uppercase" form of a comma/apostrophe/period is NOT a plain
-- ASCII space + punctuation. On the Ergopti Shift layer the comma key emits a
-- NARROW no-break space (NNBSP, U+202F) + ";", the period key emits a full
-- no-break space (NBSP, U+00A0) + ":" and the apostrophe key emits NNBSP + "?"
-- (French typography pairs ";" with the narrow space and ":" with the full one).
-- That precise emission lives in the AHK layout only -- macOS input goes through
-- Karabiner -- so these tables are the MATCHING side and stay deliberately
-- lenient: they pair both no-break spaces with both ":" and ";" so "DS" expands
-- regardless of which no-break space landed in the buffer, while a bare
-- "<space>:D" (the ":D" emoji typed after a normal word) stays literal. A plain
-- ASCII space here was a bug on two counts: it never matched the layout-emitted
-- shifted punctuation, and it DID match a space-prefixed emoji and swallowed it
-- into the expansion. Mirrors the AHK _BuildUppercasedSymbols table in
-- hotstring_engine.ahk.
local _NNBSP = "\226\128\175"  -- U+202F -- narrow no-break space (Shift+comma, before ";")
local _NBSP  = "\194\160"      -- U+00A0 -- full no-break space (Shift+period, before ":")
M.UPPER_TRIGGERS["'"] = { _NNBSP .. "?", _NBSP .. "?" }
M.UPPER_TRIGGERS[","] = { _NNBSP .. ":", _NNBSP .. ";", _NBSP .. ":", _NBSP .. ";" }
M.UPPER_TRIGGERS["."] = { _NNBSP .. ":", _NBSP .. ":" }





-- ===========================================
-- ===========================================
-- ======= 4/ Case Conversion Routines =======
-- ===========================================
-- ===========================================

--- Checks if a character is considered a valid letter.
--- @param c string The character to test.
--- @return boolean True if it is a letter.
function M.is_letter_char(c)
	if type(c) ~= "string" or c == "" then return false end
	if c:match("[%w]") then return true end
	if M.UPPER_LETTERS[c] or M.LOWER_LETTERS[c] then return true end
	return string.upper(c) ~= string.lower(c)
end

--- Word character, for the hotstring word-boundary rule ONLY.
---
--- An `is_word` trigger fires only when the character in front of it is not one
--- of these. Shared because the three drivers had three different answers and
--- nothing compared them: this engine treated every non-ASCII codepoint as a word
--- character, macOS asked is_letter_char (so "★" and "_" opened a word there but
--- nowhere else), and AutoHotkey tests membership of the word-terminator set.
--- Only the macOS/Linux pair can share an implementation; the AHK side is pinned
--- by the shared corpus instead.
---
--- @param ch string A single UTF-8 character.
--- @return boolean True when `ch` is part of a word.
function M.is_hotstring_word_char(ch)
	if type(ch) ~= "string" or ch == "" then return false end
	-- Every non-ASCII codepoint counts, deliberately: accented letters must behave
	-- like letters and there is no Unicode category table here. The magic key
	-- inherits it, which is why a word-boundary trigger typed straight after ★ does
	-- not fire — surprising, but the alternative treats "é" as punctuation.
	if ch:byte(1) > 127 then return true end
	-- "@" is not a letter and opens no word either: what follows it is the rest of
	-- an address or a handle, never a new word.
	if ch == "@" then return true end
	return ch:match("^[%w_]$") ~= nil
end

--- Safely converts a trigger string to lowercase.
--- @param s string The string to convert.
--- @return string The lowercase string.
function M.trig_lower(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
		return M.LOWER_LETTERS[c] or string.lower(c)
	end))
end

-- Memoization caches: both trig_upper and trig_title are pure functions of
-- their input. At startup, M.add() calls trig_upper/trig_title on ~3.3k
-- lowercase triggers and many short rests share identical values across
-- entries, so caching eliminates a large fraction of the array allocations.
-- Returned arrays must be treated as read-only by callers.
local _trig_upper_cache = {}
local _trig_title_cache = {}

--- Clears the case-variant memoization caches. Call when the UPPER_TRIGGERS
--- table or any lower/upper mapping changes (e.g., driver reconfiguration).
function M.clear_trig_case_caches()
	_trig_upper_cache = {}
	_trig_title_cache = {}
end

--- Generates all possible uppercase variants of a trigger.
--- @param s string The string to convert.
--- @return table An array of possible uppercase variants.
function M.trig_upper(s)
	if type(s) ~= "string" then return {""} end

	local cached = _trig_upper_cache[s]
	if cached then return cached end

	local results = {""}
	for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local map_val = M.UPPER_TRIGGERS[c]
		local uppers = {}

		if type(map_val) == "table" then
			uppers = map_val
		elseif type(map_val) == "string" then
			table.insert(uppers, map_val)
		else
			table.insert(uppers, string.upper(c))
		end

		local new_results = {}
		for _, res in ipairs(results) do
			for _, u in ipairs(uppers) do
				table.insert(new_results, res .. u)
			end
		end
		results = new_results
	end

	_trig_upper_cache[s] = results
	return results
end

--- Generates all possible Title Case variants of a trigger.
--- @param s string The string to convert.
--- @return table An array of possible Title Case variants.
function M.trig_title(s)
	if type(s) ~= "string" then return {""} end

	local cached = _trig_title_cache[s]
	if cached then return cached end

	local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
	if not first then
		local fallback = {s}
		_trig_title_cache[s] = fallback
		return fallback
	end

	local first_uppers = M.trig_upper(first)
	local rest         = M.trig_lower(s:sub(#first + 1))

	local results = {}
	for _, fu in ipairs(first_uppers) do
		table.insert(results, fu .. rest)
	end

	_trig_title_cache[s] = results
	return results
end

--- Quotes a value for POSIX sh, so it can be interpolated into a shell command.
--- Lua's string.format("%q", …) escapes for a LUA LITERAL: it handles backslashes,
--- quotes and newlines but leaves $, backticks and ! untouched — every one of which
--- /bin/sh expands. Paths in this driver are user-configurable (the config
--- directory is a setting), so %q-quoting them is a shell-injection hazard as well
--- as simply wrong for any path containing those characters.
--- Single quotes disable every expansion; an embedded quote is closed, escaped and
--- reopened, the standard POSIX idiom.
--- @param value any The value to quote (coerced with tostring).
--- @return string The value wrapped in single quotes, safe for /bin/sh.
function M.shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Escapes a value for interpolation INSIDE an AppleScript double-quoted string.
---
--- AppleScript string literals treat the backslash as an escape character, so a
--- value carrying one must have it doubled. Escaping only the double quote —
--- what every call site here did — leaves a path like `~/My\Folder` producing a
--- literal AppleScript never meant to run: at best the script errors, at worst
--- a crafted value closes the string and appends statements of its own. The
--- backslash must be escaped FIRST, or the backslashes introduced while
--- escaping the quotes get escaped in turn.
---
--- The caller supplies the surrounding quotes, mirroring how the AppleScript
--- source is written: `"…\"%s\"…"`.
--- @param value any The value to escape (coerced with tostring).
--- @return string The value with backslashes and double quotes escaped.
function M.applescript_escape(value)
	local escaped = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
	return escaped
end

--- Formats an AppleScript source string, escaping every interpolated value.
---
--- `applescript_escape` is opt-in, and opt-in is how this class kept regressing:
--- a call site would escape one of its two interpolated values and leave the
--- other raw, which is not a shape any checker can spot — the line looks right
--- and the argument list is simply one escape short. Formatting through here
--- makes the escape structural, so the only thing a reviewer or a guard has to
--- verify is WHICH formatter was used.
---
--- Numbers and booleans are passed through untouched: they cannot carry a
--- backslash or a quote, and escaping them would coerce them to strings and break
--- `%d`.
---
--- @param fmt string The AppleScript source with standard string.format placeholders.
--- @param ... any Values to interpolate; every string one is escaped.
--- @return string The formatted AppleScript source.
function M.applescript_format(fmt, ...)
	local args = table.pack(...)
	for i = 1, args.n do
		if type(args[i]) == "string" then
			args[i] = M.applescript_escape(args[i])
		end
	end
	return string.format(fmt, table.unpack(args, 1, args.n))
end

--- Escapes a string so it is safe to use as the REPLACEMENT argument of gsub.
--- Lua treats "%" specially on that side: "%1".."%9" are capture references, "%%"
--- is a literal percent, and "%" followed by anything else RAISES "invalid use of
--- '%' in replacement string". Any value that originates from the user or from a
--- third party (an app name, the configurable magic key, a release tag) must go
--- through here before being interpolated, or the whole call site throws.
--- @param s any The replacement text (coerced with tostring).
--- @return string The text with every "%" doubled.
function M.escape_gsub_replacement(s)
	return (tostring(s):gsub("%%", "%%%%"))
end

--- Safely converts a replacement string to uppercase.
--- @param s string The string to convert.
--- @return string The uppercase string.
function M.repl_upper(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
		return M.UPPER_LETTERS[c] or string.upper(c)
	end))
end

--- Safely converts a replacement string to Title Case.
--- @param s string The string to convert.
--- @return string The Title Case string.
function M.repl_title(s)
	if type(s) ~= "string" then return "" end

	local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
	if not first then return s end

	return M.repl_upper(first) .. s:sub(#first + 1)
end

--- Conforms a lowercase replacement's case to how the trigger was actually typed.
--- This is the fire-time half of the case-conform optimisation (the macOS mirror
--- of the AHK _HSE_ConformReplacement): the registry stores ONE lowercase spec
--- instead of separate lower/Title/UPPER variants, and the expander calls this
--- when the spec fires to pick the output casing from the typed trigger.
---
--- Returns nil when the typed case is not a clean lower / Title / UPPER form — the
--- hotstring must then NOT fire, exactly as the old code registered no variant for
--- a mixed-case trigger. Comparisons are case-SENSITIVE (Lua == on bytes).
---
--- Eligible triggers carry no shift-symbol chars, so trig_title/trig_upper each
--- yield a single variant; the Title check precedes the UPPER check so a
--- single-character body (Title == UPPER) correctly maps a typed capital to Title.
--- @param repl_lower string The registered (lowercase) replacement.
--- @param typed string The trigger exactly as typed (the matched buffer suffix).
--- @param canonical_lower string The registered (lowercase) trigger.
--- @return string|nil The conformed replacement, or nil to suppress the fire.
function M.conform_replacement(repl_lower, typed, canonical_lower)
	if typed == canonical_lower then
		return repl_lower
	end
	local title = M.trig_title(canonical_lower)[1]
	if title and typed == title and title ~= canonical_lower then
		return M.repl_title(repl_lower)
	end
	local upper = M.trig_upper(canonical_lower)[1]
	if upper and typed == upper then
		return M.repl_upper(repl_lower)
	end
	return nil
end

return M
