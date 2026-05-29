--- shared/lua/hotstring_engine/init.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (shared)
--- DESCRIPTION:
--- Pure-Lua hotstring matching engine with no OS dependencies. Canonical
--- implementation shared by all Lua-based drivers (Hammerspoon, Linux, and any
--- future driver). Maintains a rolling typing buffer and checks for trigger
--- matches on every keypress.
---
--- Implements the matching algorithm defined in:
---   static/ergopti_plus/shared/domain/HotstringMatcher.spec.js
---
--- FEATURES & RATIONALE:
--- 1. Tail-char bucketing: mappings are indexed by the last codepoint of their
---    trigger so only the relevant bucket is scanned per keypress — O(1) lookup
---    regardless of the total number of hotstrings.
--- 2. Longest-match-first: within a bucket, mappings are sorted by trigger
---    length descending so a longer trigger is never shadowed by a shorter one.
--- 3. Word-boundary enforcement: is_word mappings only fire when preceded by a
---    non-word character (space, tab, punctuation) or start-of-buffer.
--- 4. Case sensitivity: case-insensitive by default; is_case_sensitive requires
---    an exact-case match.
--- 5. No global state: the engine is instantiated via M.new() so multiple
---    independent hotstring contexts can coexist in the same process.
--- 6. Logger shim: works without lib.logger present (standalone daemon outside
---    Hammerspoon); falls back to plain print() transparently.
--- ==============================================================================

local M = {}




-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")

local LOG = "shared.hotstring_engine"




-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Rolling buffer capacity; keeps memory bounded while covering any realistic
-- trigger length. Triggers longer than this will never match.
local BUFFER_MAX_CHARS = 256

-- Magic key codepoint (★ = U+2605, UTF-8: 0xE2 0x98 0x85).
local MAGIC_KEY_CHAR = "\xe2\x98\x85"  -- luacheck: ignore 211 (used by callers via M.MAGIC_KEY_CHAR)
M.MAGIC_KEY_CHAR = MAGIC_KEY_CHAR




-- =========================================
-- =========================================
-- ======= 3/ Internal Helpers =============
-- =========================================
-- =========================================

--- Returns true when the character is a Unicode word character
--- (letter, digit, or underscore). Punctuation and whitespace return false.
--- Lua pattern %w matches ASCII letters/digits; non-ASCII bytes are treated as
--- word characters so accented letters behave consistently.
--- @param ch string Single UTF-8 character (may be multi-byte).
--- @return boolean
local function is_word_char(ch)
	if ch == nil or ch == "" then return false end
	-- Non-ASCII bytes (accented letters, CJK, etc.) are treated as word chars.
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
		if     b < 0x80 then len = 1
		elseif b < 0xC0 then len = 1  -- Bare continuation byte — treat as single byte.
		elseif b < 0xE0 then len = 2
		elseif b < 0xF0 then len = 3
		else                  len = 4
		end
		len = math.min(len, #s - i + 1)
		cps[#cps + 1] = s:sub(i, i + len - 1)
		i = i + len
	end
	return cps, #cps
end

--- Returns the last n codepoints of a codepoint array as a joined string.
--- @param cps   table  Codepoint array produced by utf8_codepoints().
--- @param n     number Number of trailing codepoints to join.
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
--- Each instance is fully independent — multiple engines can coexist without
--- shared state, which is useful for sandboxed testing and multi-context daemons.
--- @return table Engine object with methods :load_mappings(), :on_char(), :reset().
function M.new()
	-- Tail-char buckets: key = lower-cased last codepoint of trigger.
	local _buckets = {}
	-- Rolling buffer stored as an array of UTF-8 codepoint byte-strings.
	local _buf_cps = {}

	local engine = {}

	--- Loads a flat list of mapping tables into the engine, replacing any
	--- previously loaded mappings. Each mapping must have at minimum:
	---   trigger           string  — the hotstring the user types
	---   replacement       string  — the text to inject
	--- Optional fields:
	---   is_word           boolean — require word boundary before trigger (default false)
	---   is_case_sensitive boolean — exact-case match required (default false)
	---   group             string  — logical group name for enable/disable
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
				local cps, n = utf8_codepoints(m.trigger)
				if n > 0 then
					-- Key the bucket by the lower-cased tail char for case-insensitive lookup.
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
		-- Sort each bucket longest-first to guarantee longest-match semantics.
		for _, bucket in pairs(_buckets) do
			table.sort(bucket, function(a, b) return a.tlen > b.tlen end)
		end
		local bucket_count = 0
		for _ in pairs(_buckets) do bucket_count = bucket_count + 1 end
		Logger.success(LOG, "Mappings loaded (%d entry(ies), %d bucket(s)).", count, bucket_count)
	end

	--- Appends a character to the rolling buffer and checks for a trigger match.
	--- Call this on every keypress (excluding modifier-only events).
	---
	--- @param ch     string  The typed character (UTF-8, one or more codepoints).
	--- @param opts   table   Optional: { terminator_consumed?: boolean }
	--- @return table|nil  On match: { trigger, replacement, backspace_count,
	---                               consume_terminator, group }.
	---                    Nil when no trigger matched.
	function engine:on_char(ch, opts)
		if type(ch) ~= "string" or ch == "" then return nil end
		local options            = type(opts) == "table" and opts or {}
		local terminator_consumed = options.terminator_consumed == true

		-- Append every codepoint of ch to the rolling buffer.
		local cps, _ = utf8_codepoints(ch)
		for _, cp in ipairs(cps) do
			_buf_cps[#_buf_cps + 1] = cp
		end
		-- Enforce the rolling window.
		while #_buf_cps > BUFFER_MAX_CHARS do
			table.remove(_buf_cps, 1)
		end

		Logger.debug(LOG, "on_char('%s'): buffer %d codepoint(s).", ch, #_buf_cps)

		-- Look up the bucket for the current tail codepoint (case-folded).
		local tail_cp = _buf_cps[#_buf_cps]:lower()
		local bucket  = _buckets[tail_cp]
		if not bucket then return nil end

		local buf_len = #_buf_cps

		for _, mapping in ipairs(bucket) do
			local tlen = mapping.tlen

			-- 1. Buffer must be at least as long as the trigger.
			if buf_len >= tlen then

				-- 2. Suffix check (case-aware).
				local buf_tail = tail_codepoints(_buf_cps, tlen)
				local matched
				if mapping.is_case_sensitive then
					matched = buf_tail == mapping.trigger
				else
					matched = buf_tail:lower() == mapping.trigger:lower()
				end

				if matched then

					-- 3. Word-boundary check: the character preceding the trigger must not
					--    be a word character (or the trigger fills the whole buffer).
					local boundary_ok = true
					if mapping.is_word and buf_len > tlen then
						local preceding = _buf_cps[buf_len - tlen]
						if is_word_char(preceding) then boundary_ok = false end
					end

					if boundary_ok then
						-- 4. Match confirmed.
						local bc = tlen + (terminator_consumed and 1 or 0)
						Logger.debug(LOG, "Match: trigger='%s' backspaces=%d.", mapping.trigger, bc)
						return {
							trigger            = mapping.trigger,
							replacement        = mapping.replacement,
							backspace_count    = bc,
							consume_terminator = terminator_consumed,
							group              = mapping.group,
						}
					end
				end
			end
		end

		return nil
	end

	--- Clears the rolling typing buffer (e.g., on focus change or Escape key).
	function engine:reset()
		_buf_cps = {}
		Logger.debug(LOG, "Buffer reset.")
	end

	return engine
end

return M
