--- _shared/lua/hotstring_engine/init.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (shared)
--- DESCRIPTION:
--- Pure-Lua hotstring matching engine with no OS dependencies. Canonical
--- implementation shared by all Lua-based drivers (Hammerspoon, Linux, and any
--- future driver). Maintains a rolling typing buffer and checks for trigger
--- matches on every keypress.
---
--- Implements the matching algorithm defined in:
---   static/ergopti_plus/_shared/core/domain/HotstringMatcher.spec.js
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

-- The two no-break spaces French typography places before ":" and ";". The
-- layout emits them as part of the keystroke, so they land in the buffer between
-- the trigger and the terminator and the matcher has to look past them.
local NNBSP_CHAR = "\xe2\x80\xaf"  -- U+202F narrow no-break space
local NBSP_CHAR  = "\xc2\xa0"      -- U+00A0 no-break space




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
						-- Absent means NOT auto, matching the AutoHotkey loader: it emits the
						-- "*" flag only when the TOML says auto_expand = true. An entry that
						-- does not opt in waits for a terminator, which is the whole point of
						-- the field — "ya" must not fire in the middle of "yaourt".
						auto_expand       = m.auto_expand       == true,
						final_result      = m.final_result      == true,
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

		local buf_len = #_buf_cps

		--- Finds the best match ending at `body_len`, over mappings selected by
		--- `want_auto`. Returns the mapping and its length, or nil.
		---
		--- Split out because the same search runs twice: once on the buffer as
		--- typed (auto_expand entries, which fire the moment the trigger
		--- completes) and once on the buffer minus a just-typed terminator
		--- (non-auto entries, which wait for one).
		local function best_match(body_len, want_auto)
			if body_len < 1 then return nil end
			local bucket = _buckets[_buf_cps[body_len]:lower()]
			if not bucket then return nil end

			for _, mapping in ipairs(bucket) do
				local tlen = mapping.tlen
				if mapping.auto_expand == want_auto and body_len >= tlen then
					-- Suffix check (case-aware), against the body rather than the
					-- whole buffer so the terminator is excluded on the end-char path.
					local buf_tail = table.concat(_buf_cps, "", body_len - tlen + 1, body_len)
					local matched
					if mapping.is_case_sensitive then
						matched = buf_tail == mapping.trigger
					else
						matched = buf_tail:lower() == mapping.trigger:lower()
					end

					if matched then
						-- Word-boundary check: the character preceding the trigger must
						-- not be a word character (or the trigger fills the whole body).
						local boundary_ok = true
						if mapping.is_word and body_len > tlen then
							if is_word_char(_buf_cps[body_len - tlen]) then boundary_ok = false end
						end
						-- The bucket is sorted longest-first, so the first survivor is
						-- the longest for this path.
						if boundary_ok then return mapping, tlen end
					end
				end
			end
			return nil
		end

		-- Path A — auto_expand: fires on the trigger's own last character.
		local auto_map, auto_len = best_match(buf_len, true)

		-- Path B — end-char: a non-auto trigger fires only when a terminator
		-- follows it, so the body excludes the character just typed.
		--
		-- French typography complicates exactly two terminators. The layout emits
		-- ":" and ";" as NNBSP+":" / NNBSP+";", so the no-break space lands in the
		-- buffer BETWEEN the trigger and the terminator and the body must exclude
		-- it too. Windows (hotstring_match.ahk) and macOS (expander.lua) both do
		-- this; Linux did not, so a trigger followed by a typographic colon simply
		-- never matched there.
		--
		-- The space is REQUIRED, not merely tolerated: a bare ":" with no nbsp
		-- before it is mid-sequence text — the ":" of ":D" — and must not end a
		-- hotstring. Only the end-char path is affected; a trigger whose own last
		-- codepoint is ":" still fires on the auto path untouched.
		local end_map, end_len, nbsp_stripped = nil, nil, false
		if options.is_terminator == true then
			local typed = _buf_cps[buf_len]
			local body_len = buf_len - 1
			local eligible = true
			if typed == ":" or typed == ";" then
				local preceding = body_len >= 1 and _buf_cps[body_len] or nil
				if preceding == NNBSP_CHAR or preceding == NBSP_CHAR then
					body_len = body_len - 1
					nbsp_stripped = true
				else
					eligible = false
				end
			end
			if eligible then
				end_map, end_len = best_match(body_len, false)
			end
			if not end_map then nbsp_stripped = false end
		end

		-- Resolve across the two paths by trigger LENGTH, which is what Windows
		-- does (_HSE_EndCharBeats: a star match yields to a strictly longer
		-- end-char trigger). macOS returns on the first auto hit instead, so the
		-- two drivers disagree today; length is the rule the three converge on.
		local mapping, tlen, via_end_char
		if auto_map and end_map then
			if end_len > auto_len then
				mapping, tlen, via_end_char = end_map, end_len, true
			else
				mapping, tlen, via_end_char = auto_map, auto_len, false
			end
		elseif auto_map then
			mapping, tlen, via_end_char = auto_map, auto_len, false
		elseif end_map then
			mapping, tlen, via_end_char = end_map, end_len, true
		else
			return nil
		end

		-- An end-char match always replaces the terminator too: it sits between
		-- the trigger and the caret, so the driver must erase it to splice the
		-- replacement in. On the auto path the caller decides.
		local consumed = via_end_char or terminator_consumed
		-- +1 for the terminator, +1 more for a stripped no-break space: both sit
		-- between the trigger and the caret, so both are replaced. Mirrors
		-- hotstring_dispatch.ahk (Spec.Length + endchar + HSE_TypoNbspStripped).
		local bc = tlen + (consumed and 1 or 0) + ((via_end_char and nbsp_stripped) and 1 or 0)
		Logger.debug(LOG, "Match: trigger='%s' backspaces=%d end_char=%s.",
			mapping.trigger, bc, tostring(via_end_char))
		return {
			trigger            = mapping.trigger,
			replacement        = mapping.replacement,
			backspace_count    = bc,
			consume_terminator = consumed,
			end_char           = via_end_char,
			final_result       = mapping.final_result,
			group              = mapping.group,
		}
	end

	--- Clears the rolling typing buffer (e.g., on focus change or Escape key).
	function engine:reset()
		_buf_cps = {}
		Logger.debug(LOG, "Buffer reset.")
	end

	--- Rewrites the buffer to reflect an expansion the driver has just injected:
	--- drops the codepoints the replacement consumed and appends the replacement
	--- itself. Call this INSTEAD of reset() when the mapping is not
	--- `final_result`, so the expanded text stays visible to the matcher and a
	--- later keystroke can complete a further trigger — which is what Windows and
	--- macOS both do. A driver that resets unconditionally can never chain.
	---
	--- Deliberately does NOT re-run matching. Chaining happens on the next real
	--- keystroke, exactly as it does on macOS, and that is what makes an
	--- expansion whose replacement contains its own trigger impossible to loop on.
	--- @param result table The table returned by on_char.
	function engine:apply_expansion(result)
		if type(result) ~= "table" then return end
		local consumed = tonumber(result.backspace_count) or 0
		for _ = 1, consumed do
			if #_buf_cps == 0 then break end
			table.remove(_buf_cps)
		end
		local cps = utf8_codepoints(result.replacement or "")
		for _, cp in ipairs(cps) do
			_buf_cps[#_buf_cps + 1] = cp
		end
		while #_buf_cps > BUFFER_MAX_CHARS do
			table.remove(_buf_cps, 1)
		end
		Logger.debug(LOG, "Expansion applied: buffer %d codepoint(s).", #_buf_cps)
	end

	--- Returns the current rolling typing buffer as a UTF-8 string. The LLM
	--- prediction engine detects its own trigger sequences in the same typing
	--- context the hotstring matcher sees, so both work off this one buffer rather
	--- than each keeping a separate copy.
	--- @return string The concatenated codepoints currently in the buffer.
	function engine:current_buffer()
		return table.concat(_buf_cps)
	end

	return engine
end

return M
