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
--- 4. Case handling in three modes, selected per entry by the TWO schema flags —
---    see load_mappings for the mapping. Note that the TOML flag
---    `is_case_sensitive` is NOT the domain spec's `is_case_sensitive`: the
---    schema flag selects the REGISTRATION shape (literal vs cased family) while
---    the spec's flag is about the COMPARISON. The spec's notion is this
---    engine's "exact" mode, which the schema spells `is_case_sensitive_strict`.
---    Reading the two same-named fields as one thing is what made 592 shared
---    entries behave differently here than on Windows, so the flags are resolved
---    once at load time into an internal `match_mode` and the ambiguous name
---    never reaches the matcher.
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

-- Case folding, the trigger's Title/UPPER variants and the fire-time replacement
-- conformance all live in the shared text utilities, which is also where macOS
-- gets them. Reimplementing any of it here would be a second Unicode case table
-- — the accented and French-punctuation mappings are the whole difficulty.
local text_utils = require("text_utils")

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

-- The word-boundary predicate is shared with macOS rather than defined here, so
-- the two drivers cannot answer differently for the same character. They did:
-- this engine's own copy omitted "@", so a trigger typed straight after an email
-- address fired here and not there.
local is_word_char = text_utils.is_hotstring_word_char

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
	---   is_word                  boolean — require a word boundary before the trigger
	---   is_case_sensitive        boolean — register the trigger LITERALLY, i.e. do
	---                                      not generate the cased family
	---   is_case_sensitive_strict boolean — compare exactly, no case folding
	---   auto_expand              boolean — fire on the trigger's own last char
	---   final_result             boolean — nothing may chain off the replacement
	---   group                    string  — logical group name for enable/disable
	---
	--- The two case flags are ORTHOGONAL and resolve to three match modes, the
	--- same three the AutoHotkey loader produces (hotstring_builder.ahk):
	---
	---   strict                     → "exact"   — only the casing written fires.
	---   is_case_sensitive, ¬strict → "fold"    — any casing fires, the
	---                                            replacement is emitted verbatim.
	---   neither                    → "conform" — any casing fires and the
	---                                            replacement takes the casing that
	---                                            was typed.
	---
	--- "fold" is what 592 shared entries need and what this engine used to get
	--- wrong: `"adn" = { output = "ADN", is_case_sensitive = true }` exists so that
	--- typing adn in ANY casing yields "ADN" — the literal registration is there to
	--- stop the family generating "Adn" → "Adn". Treating the flag as "compare
	--- exactly" meant typing "Adn" simply did nothing.
	--- @param mappings table Array of mapping tables.
	function engine:load_mappings(mappings)
		Logger.start(LOG, "Loading mappings…")
		_buckets = {}
		if type(mappings) ~= "table" then
			Logger.error(LOG, "load_mappings(): expected table, got %s.", type(mappings))
			return
		end

		local registered = 0

		--- Files one ready-resolved entry into the bucket of its tail codepoint.
		--- @param trigger string The trigger exactly as the matcher will compare it.
		--- @param replacement string The text this trigger injects.
		--- @param mode string One of "exact", "fold", "conform".
		--- @param source table The originating mapping, for the flags shared by every
		---   entry derived from it.
		local function register(trigger, replacement, mode, source)
			local cps, n = utf8_codepoints(trigger)
			if n == 0 then return end
			-- Bucket key: the tail codepoint, Unicode-folded. trig_lower rather than
			-- string.lower because the latter is ASCII-only, so an accented tail typed
			-- as "Ê" probed a bucket registered under "ê" and never matched.
			local key    = text_utils.trig_lower(cps[n])
			local bucket = _buckets[key]
			if not bucket then bucket = {} ; _buckets[key] = bucket end
			bucket[#bucket + 1] = {
				trigger      = trigger,
				-- Canonical side of a "fold" compare, precomputed so the hot path folds
				-- only what the user typed. The trigger itself stays AS WRITTEN, because
				-- it is what every consumer of a match result sees.
				trigger_folded = mode == "fold" and text_utils.trig_lower(trigger) or nil,
				replacement  = replacement,
				tlen         = n,
				match_mode   = mode,
				is_word      = source.is_word == true,
				-- Absent means NOT auto, matching the AutoHotkey loader: it emits the
				-- "*" flag only when the TOML says auto_expand = true. An entry that
				-- does not opt in waits for a terminator, which is the whole point of
				-- the field — "ya" must not fire in the middle of "yaourt".
				auto_expand  = source.auto_expand == true,
				final_result = source.final_result == true,
				-- Collision priority, already through the cascade by the time it gets
				-- here (the loader owns the source tier, because only it knows which
				-- file an entry came from). Absent means "the caller has no opinion",
				-- and every such entry scores the same, so relative order is unchanged.
				priority     = tonumber(source.priority) or 0,
				group        = source.group or "",
				-- Registration order, the FINAL tiebreak. Lua's table.sort is not
				-- stable, so two entries equal on every other key came out in an order
				-- that depended on the sort's internals — a collision could elect a
				-- different winner between two runs of the same corpus.
				seq          = registered + 1,
			}
			registered = registered + 1
		end

		--- Registers a mapping that has opted into case conformance.
		---
		--- One entry suffices whenever the trigger's Title and UPPER forms are each
		--- unique and the same length as the lowercase form, because conforming at
		--- fire time then reproduces exactly what registering the three variants
		--- would have. That is the overwhelming majority and it is also what macOS
		--- does, for the same reason.
		---
		--- It does NOT suffice when a character's shifted form is a different
		--- character or a different NUMBER of characters — on this layout the comma
		--- shifts to no-break-space + ";" — because the variant then has its own
		--- length and its own tail codepoint, so it belongs in its own bucket. Those
		--- are registered explicitly, exactly as macOS registers them.
		--- @param m table The source mapping.
		local function register_case_family(m)
			local lower      = text_utils.trig_lower(m.trigger)
			local _, lower_n = utf8_codepoints(lower)
			local titles     = text_utils.trig_title(lower)
			local uppers     = text_utils.trig_upper(lower)

			local function same_shape(variants)
				if #variants ~= 1 then return false end
				local _, n = utf8_codepoints(variants[1])
				return n == lower_n
			end

			if same_shape(titles) and same_shape(uppers) then
				register(lower, m.replacement, "conform", m)
				return
			end

			register(lower, m.replacement, "exact", m)
			for _, t in ipairs(titles) do
				if t ~= lower then register(t, text_utils.repl_title(m.replacement), "exact", m) end
			end
			for _, u in ipairs(uppers) do
				-- A single-character body has Title == UPPER. Registering both would put
				-- two entries with the same trigger and the same replacement in one
				-- bucket, which the tooltip would then offer twice.
				local is_title = false
				for _, t in ipairs(titles) do
					if u == t then is_title = true ; break end
				end
				if u ~= lower and not is_title then
					register(u, text_utils.repl_upper(m.replacement), "exact", m)
				end
			end
		end

		local loaded = 0
		for _, m in ipairs(mappings) do
			if type(m.trigger) == "string" and m.trigger ~= "" and type(m.replacement) == "string" then
				if m.is_case_sensitive_strict == true then
					register(m.trigger, m.replacement, "exact", m)
				elseif m.is_case_sensitive == true then
					register(m.trigger, m.replacement, "fold", m)
				else
					register_case_family(m)
				end
				loaded = loaded + 1
			end
		end

		-- Sort each bucket longest-first, then by collision priority, then by
		-- registration order. Same key order as the macOS registry and the
		-- AutoHotkey engine: LENGTH is primary, so a longer trigger beats a
		-- higher-priority shorter one — priority only arbitrates a genuine tie.
		for _, bucket in pairs(_buckets) do
			table.sort(bucket, function(a, b)
				if a.tlen ~= b.tlen then return a.tlen > b.tlen end
				if a.priority ~= b.priority then return a.priority > b.priority end
				return a.seq < b.seq
			end)
		end
		local bucket_count = 0
		for _ in pairs(_buckets) do bucket_count = bucket_count + 1 end
		Logger.success(LOG, "Mappings loaded (%d mapping(s) → %d entry(ies), %d bucket(s)).",
			loaded, registered, bucket_count)
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
			local bucket = _buckets[text_utils.trig_lower(_buf_cps[body_len])]
			if not bucket then return nil end

			for _, mapping in ipairs(bucket) do
				local tlen = mapping.tlen
				if mapping.auto_expand == want_auto and body_len >= tlen then
					-- Suffix check (case-aware), against the body rather than the
					-- whole buffer so the terminator is excluded on the end-char path.
					local buf_tail = table.concat(_buf_cps, "", body_len - tlen + 1, body_len)
					-- The effective replacement, which is the mapping's own EXCEPT in
					-- conform mode where it takes the casing that was typed. nil means
					-- this mapping does not fire: conform_replacement rejects a casing
					-- that is neither lower, Title nor UPPER, because no variant would
					-- have been registered for it.
					local eff
					local mode = mapping.match_mode
					if mode == "exact" then
						if buf_tail == mapping.trigger then eff = mapping.replacement end
					elseif mode == "fold" then
						if text_utils.trig_lower(buf_tail) == mapping.trigger_folded then
							eff = mapping.replacement
						end
					else
						if text_utils.trig_lower(buf_tail) == mapping.trigger then
							eff = text_utils.conform_replacement(mapping.replacement, buf_tail, mapping.trigger)
						end
					end

					if eff then
						-- Word-boundary check: the character preceding the trigger must
						-- not be a word character (or the trigger fills the whole body).
						local boundary_ok = true
						if mapping.is_word and body_len > tlen then
							if is_word_char(_buf_cps[body_len - tlen]) then boundary_ok = false end
						end
						-- The bucket is sorted longest-first, so the first survivor is
						-- the longest for this path.
						if boundary_ok then return mapping, tlen, eff end
					end
				end
			end
			return nil
		end

		-- Path A — auto_expand: fires on the trigger's own last character.
		local auto_map, auto_len, auto_repl = best_match(buf_len, true)

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
		local end_map, end_len, end_repl, nbsp_stripped = nil, nil, nil, false
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
				end_map, end_len, end_repl = best_match(body_len, false)
			end
			if not end_map then nbsp_stripped = false end
		end

		-- Resolve across the two paths by trigger LENGTH, which is what Windows
		-- does (_HSE_EndCharBeats: a star match yields to a strictly longer
		-- end-char trigger). macOS returns on the first auto hit instead, so the
		-- two drivers disagree today; length is the rule the three converge on.
		local mapping, tlen, replacement, via_end_char
		if auto_map and end_map then
			if end_len > auto_len then
				mapping, tlen, replacement, via_end_char = end_map, end_len, end_repl, true
			else
				mapping, tlen, replacement, via_end_char = auto_map, auto_len, auto_repl, false
			end
		elseif auto_map then
			mapping, tlen, replacement, via_end_char = auto_map, auto_len, auto_repl, false
		elseif end_map then
			mapping, tlen, replacement, via_end_char = end_map, end_len, end_repl, true
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
			-- The EFFECTIVE replacement, which in conform mode carries the casing the
			-- user typed rather than the casing stored at registration. Returning the
			-- stored one would make every conform entry emit lowercase.
			replacement        = replacement,
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
