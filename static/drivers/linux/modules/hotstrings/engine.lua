--- static/drivers/linux/modules/hotstrings/engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (Linux)
--- DESCRIPTION:
--- Pure-Lua hotstring matching engine with no OS dependencies. Maintains a
--- rolling typing buffer and checks for trigger matches on every keypress.
--- Implements the canonical matching algorithm defined in
--- static/drivers/_shared/domain/HotstringMatcher.spec.js so that behaviour is
--- identical across the AHK, Hammerspoon, and Linux drivers.
---
--- FEATURES & RATIONALE:
--- 1. Tail-char bucketing: mappings are indexed by the last codepoint of their
---    trigger so only the relevant bucket is scanned per keypress.
--- 2. Longest-match-first: within a bucket, mappings are sorted by trigger
---    length descending so a longer trigger is never shadowed by a shorter one.
--- 3. Word-boundary enforcement: is_word mappings only fire when preceded by a
---    non-word character (space, tab, punctuation) or start-of-buffer.
--- 4. Case sensitivity: case-insensitive by default; is_case_sensitive requires
---    an exact-case match.
--- 5. No global state: the engine is instantiated via M.new() so multiple
---    independent hotstring contexts can coexist in the same process.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

-- Graceful fallback: if lib.logger is absent (standalone daemon outside
-- Hammerspoon), map every level to a plain print so the rest of the code
-- never needs nil-guards around Logger calls.
local Logger = (function()
	local ok, lib = pcall(require, "lib.logger")
	if ok and lib then return lib end
	local function _log(level, tag, fmt, ...)
		local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		print(string.format("[%s] [%s] %s", level, tag, msg))
	end
	return {
		debug   = function(t, f, ...) _log("DEBUG",   t, f, ...) end,
		trace   = function(t, f, ...) _log("TRACE",   t, f, ...) end,
		done    = function(t, f, ...) _log("DONE",    t, f, ...) end,
		info    = function(t, f, ...) _log("INFO",    t, f, ...) end,
		start   = function(t, f, ...) _log("START",   t, f, ...) end,
		success = function(t, f, ...) _log("SUCCESS", t, f, ...) end,
		warn    = function(t, f, ...) _log("WARN",    t, f, ...) end,
		error   = function(t, f, ...) _log("ERROR",   t, f, ...) end,
	}
end)()

local LOG = "modules.hotstrings.engine"


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Rolling buffer capacity; keeps memory bounded while covering any realistic
-- trigger length. Triggers longer than this will never match.
local BUFFER_MAX_CHARS = 256

-- Magic key codepoint used for the star-bucket (★ = U+2605).
local MAGIC_KEY_CHAR = "\xe2\x98\x85"


-- =========================================
-- =========================================
-- ======= 3/ Internal Helpers =============
-- =========================================
-- =========================================

--- Returns true when the character is a Unicode word character
--- (letter, digit, or underscore). Punctuation and whitespace return false.
--- Lua pattern %w matches ASCII letters/digits; we also accept _ and high bytes
--- as word chars so accented letters are treated consistently.
--- @param ch string Single UTF-8 character (may be multi-byte).
--- @return boolean
local function is_word_char(ch)
	if ch == nil or ch == "" then return false end
	-- Non-ASCII bytes: treat as word characters (letters with diacritics, etc.)
	if ch:byte(1) > 127 then return true end
	return ch:match("^[%w_]$") ~= nil
end

--- Splits a UTF-8 string into a sequence of codepoint byte-strings.
--- Returns a table of single-codepoint strings and the total codepoint count.
--- @param s string UTF-8 string.
--- @return table, number
local function utf8_codepoints(s)
	local cps = {}
	local i = 1
	while i <= #s do
		local b = s:byte(i)
		local len
		if     b < 0x80  then len = 1
		elseif b < 0xC0  then len = 1  -- continuation byte — treat as byte
		elseif b < 0xE0  then len = 2
		elseif b < 0xF0  then len = 3
		else                   len = 4
		end
		len = math.min(len, #s - i + 1)
		cps[#cps + 1] = s:sub(i, i + len - 1)
		i = i + len
	end
	return cps, #cps
end

--- Returns the last n codepoints of a codepoint table as a joined string.
--- @param cps   table  Codepoint array.
--- @param n     number Number of trailing codepoints.
--- @return string
local function tail_codepoints(cps, n)
	local start = #cps - n + 1
	if start < 1 then start = 1 end
	local parts = {}
	for i = start, #cps do
		parts[#parts + 1] = cps[i]
	end
	return table.concat(parts)
end


-- =========================================
-- =========================================
-- ======= 4/ Engine Instance ==============
-- =========================================
-- =========================================

--- Creates a new hotstring engine instance.
--- @return table Engine object exposing :load_mappings(), :on_char(), :reset().
function M.new()
	-- Buckets indexed by the last codepoint of each trigger (lower-cased key).
	local _buckets = {}
	-- Rolling buffer stored as an array of UTF-8 codepoint strings.
	local _buf_cps = {}

	local engine = {}

	--- Loads a flat list of mapping tables into the engine, replacing any
	--- previously loaded mappings. Each mapping must have:
	---   trigger           string
	---   replacement       string
	---   is_word           boolean (optional, default false)
	---   is_case_sensitive boolean (optional, default false)
	---   group             string  (optional)
	--- @param mappings table Array of mapping tables.
	function engine:load_mappings(mappings)
		Logger.start(LOG, "Loading mappings…")
		_buckets = {}
		if type(mappings) ~= "table" then
			Logger.error(LOG, "load_mappings(): expected table, got %s.", type(mappings))
			return
		end
		local count = 0
		for _, m in ipairs(mappings) do
			if type(m.trigger) == "string" and type(m.replacement) == "string" then
				-- Key the bucket by the lower-cased last codepoint for case-insensitive lookup.
				local cps, n = utf8_codepoints(m.trigger)
				if n > 0 then
					local tail_cp = cps[n]:lower()
					if not _buckets[tail_cp] then _buckets[tail_cp] = {} end
					_buckets[tail_cp][#_buckets[tail_cp] + 1] = {
						trigger           = m.trigger,
						replacement       = m.replacement,
						tlen              = n,
						is_word           = m.is_word           == true,
						is_case_sensitive = m.is_case_sensitive == true,
						group             = m.group or "",
					}
					count = count + 1
				end
			end
		end
		-- Sort each bucket longest-first to ensure longest-match semantics.
		for _, bucket in pairs(_buckets) do
			table.sort(bucket, function(a, b) return a.tlen > b.tlen end)
		end
		Logger.success(LOG, "Mappings loaded (%d entry(ies), %d bucket(s)).", count, (function()
			local n = 0; for _ in pairs(_buckets) do n = n + 1 end; return n
		end)())
	end

	--- Appends a character to the rolling buffer and checks for a match.
	--- Returns a match result table or nil.
	--- @param ch     string  The typed character (UTF-8, one codepoint).
	--- @param opts   table   { terminator_consumed?: boolean }
	--- @return table|nil  { trigger, replacement, backspace_count, consume_terminator, group }
	function engine:on_char(ch, opts)
		if type(ch) ~= "string" or ch == "" then return nil end
		local options = type(opts) == "table" and opts or {}
		local terminator_consumed = options.terminator_consumed == true

		-- Append to rolling buffer; keep size bounded.
		local cps, _ = utf8_codepoints(ch)
		for _, cp in ipairs(cps) do
			_buf_cps[#_buf_cps + 1] = cp
		end
		while #_buf_cps > BUFFER_MAX_CHARS do
			table.remove(_buf_cps, 1)
		end

		Logger.debug(LOG, "on_char('%s'): buffer length %d codepoint(s).", ch, #_buf_cps)

		-- Determine the bucket key from the last codepoint (lower-cased).
		local tail_cp = _buf_cps[#_buf_cps]:lower()
		local bucket  = _buckets[tail_cp]
		if not bucket then return nil end

		local buf_len = #_buf_cps

		for _, mapping in ipairs(bucket) do
			local tlen = mapping.tlen

			-- 1. Buffer must be at least as long as the trigger.
			if buf_len < tlen then goto continue end

			-- 2. Suffix check (case-aware).
			local buf_tail = tail_codepoints(_buf_cps, tlen)
			local matched
			if mapping.is_case_sensitive then
				matched = buf_tail == mapping.trigger
			else
				matched = buf_tail:lower() == mapping.trigger:lower()
			end
			if not matched then goto continue end

			-- 3. Word-boundary check.
			if mapping.is_word then
				if buf_len > tlen then
					local preceding = _buf_cps[buf_len - tlen]
					if is_word_char(preceding) then goto continue end
				end
				-- Start-of-buffer counts as a word boundary — allow match.
			end

			-- 4. Match found.
			local bc = tlen + (terminator_consumed and 1 or 0)
			Logger.debug(LOG, "Match: trigger='%s' bc=%d.", mapping.trigger, bc)
			return {
				trigger            = mapping.trigger,
				replacement        = mapping.replacement,
				backspace_count    = bc,
				consume_terminator = terminator_consumed,
				group              = mapping.group,
			}

			::continue::
		end

		return nil
	end

	--- Clears the typing buffer (e.g., on focus change or Escape).
	function engine:reset()
		_buf_cps = {}
		Logger.debug(LOG, "Buffer reset.")
	end

	return engine
end

return M
