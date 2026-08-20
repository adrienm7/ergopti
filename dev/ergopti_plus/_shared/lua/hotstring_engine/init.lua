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

-- ===============================================
-- ===============================================
-- ======= 4/ The Matcher, as a pure function ====
-- ===============================================
-- ===============================================

--- Decides whether ONE mapping fires, from the only two facts about the buffer
--- that the decision actually depends on.
---
--- WHY THIS TAKES STRINGS AND NOT A BUFFER — this is what unblocked the macOS
--- adoption after two other blockers had already been removed.
--- The matcher looked stuck behind a representation choice: macOS holds its
--- buffer as a BYTE STRING and slices it with `buffer:sub(-trigger_bytes)`, this
--- core holds an ARRAY OF CODEPOINTS and slices it with `table.concat`. Feeding
--- either to the other read as a per-keystroke conversion — on the exact path
--- where overrunning the deadline makes macOS disable the event tap and stop the
--- driver, not merely drop a key. The choice on offer was "macOS converts its
--- buffer" or "the core carries a second representation", and both are bad.
---
--- The buffer was never an input to the decision. Read side by side, both
--- predicates consume exactly (1) the buffer tail of the trigger's own length and
--- (2) the single codepoint in front of it. SLICING is representation-specific
--- and each driver already does it in O(1) in its own representation; DECIDING is
--- not. So the slice stays with the driver and the decision comes here, and the
--- second representation is not chosen — it stops being needed.
---
--- The order of the checks is macOS's, deliberately: a mapping that is both
--- word-boundary-blocked and a no-op must report BLOCKED, because `is_noop`
--- drives a cleanup path (suppress the rescan, hide the tooltip) that a blocked
--- match must not enter.
---
--- @param mapping table Match rules: match_mode, trigger, trigger_folded, is_word.
--- @param plain string The plain replacement under consideration. Passed rather
---   than read off `mapping` because the two registries genuinely differ, and not
---   by accident: macOS carries a raw replacement that may hold {Token} directives
---   AND a plain one, and only the plain one takes part in the decision.
--- @param typed string The buffer tail, exactly as long as the trigger.
--- @param prev_char string|nil The codepoint immediately in front of `typed`, or
---   nil when `typed` starts the buffer. An EMPTY string means "something is there
---   but could not be decoded", which is a different thing and must NOT consult
---   `start_is_boundary` — malformed UTF-8 has always been tolerated here.
--- @param start_is_boundary boolean Whether the buffer's own start abuts a known
---   word terminator. Consulted only when `prev_char` is nil.
--- @return string|nil eff The effective replacement, or nil when it does not fire.
--- @return boolean is_noop True when it matched but would replace text with itself.
function M.decide(mapping, plain, typed, prev_char, start_is_boundary)
	if type(mapping) ~= "table" or type(typed) ~= "string" or type(plain) ~= "string" then
		return nil, false
	end

	-- The effective replacement, which is the mapping's own EXCEPT in conform
	-- mode where it takes the casing that was typed. nil means this mapping does
	-- not fire: conform_replacement rejects a casing that is neither lower, Title
	-- nor UPPER, because no variant would have been registered for it.
	local eff
	local mode = mapping.match_mode
	if mode == "exact" then
		if typed == mapping.trigger then eff = plain end
	elseif mode == "fold" then
		if text_utils.trig_lower(typed) == mapping.trigger_folded then eff = plain end
	elseif mode == "conform" then
		if text_utils.trig_lower(typed) == mapping.trigger then
			eff = text_utils.conform_replacement(plain, typed, mapping.trigger)
		end
	else
		-- Fail fast rather than defaulting. "conform" used to be the catch-all
		-- branch, so a mapping that reached here with no match_mode silently became
		-- case-insensitive — and for a lowercase trigger it then produced the right
		-- answer for the wrong reason, which is the shape of thing that survives a
		-- test suite. Both registries set the field on every entry; anything that
		-- does not is a construction bug and should look like one.
		Logger.error(LOG, "decide(): mapping '%s' has no match_mode — refusing to guess.",
			tostring(mapping.trigger))
		return nil, false
	end
	if not eff then return nil, false end

	-- Word-boundary check, and the three drivers had three different answers to it
	-- with only ever two agreeing at once — which is the whole reason it is now
	-- written down once. macOS exempted any trigger whose first BYTE was one of a
	-- separator set, AutoHotkey exempted nothing, and this core skipped the check
	-- entirely when the trigger filled the buffer instead of consulting the
	-- start-of-buffer flag that the other two both consult.
	if mapping.is_word then
		if prev_char == nil then
			if not start_is_boundary then return nil, false end
		elseif is_word_char(prev_char) then
			return nil, false
		end
	end

	-- No-op guard. A mapping whose effective replacement equals what was typed
	-- has nothing to inject, and reporting it as a match is not harmless: the
	-- caller consumes the triggering keystroke to make room for an expansion that
	-- then writes the same characters back. macOS shipped without this guard once
	-- and the character vanished from the screen — the dropped-char bug its own
	-- try_auto_expand comment names. This core had none at all; the divergence was
	-- invisible because no corpus vector covered a no-op until 2026-08-04.
	if eff == typed then return nil, true end

	return eff, false
end

--- Answers M.decide for a codepoint-array buffer: does `mapping` fire ending at
--- `body_len`?
---
--- The codepoint half of the split described above. It does the slicing this
--- representation makes cheap, and nothing else — every rule lives in M.decide,
--- so macOS calling that directly from a byte string cannot drift from this.
---
--- @param mapping table A loaded mapping (match_mode, trigger, tlen, …).
--- @param buf_cps table Array of UTF-8 codepoint strings.
--- @param body_len number Index the candidate trigger must end at.
--- @param start_is_boundary boolean Whether the buffer's start abuts a terminator.
--- @return string|nil eff Effective replacement, or nil when it does not fire.
--- @return string|nil typed The buffer tail that matched, for the caller's arithmetic.
function M.mapping_fires(mapping, buf_cps, body_len, start_is_boundary)
	if type(mapping) ~= "table" or type(buf_cps) ~= "table" then return nil end
	local tlen = mapping.tlen
	if type(tlen) ~= "number" or type(body_len) ~= "number" or body_len < tlen then return nil end

	-- Sliced against the body rather than the whole buffer, so the terminator is
	-- excluded on the end-char path.
	local typed     = table.concat(buf_cps, "", body_len - tlen + 1, body_len)
	local prev_char = body_len > tlen and buf_cps[body_len - tlen] or nil

	local eff = M.decide(mapping, mapping.replacement, typed, prev_char, start_is_boundary)
	if not eff then return nil end
	return eff, typed
end

--- Finds the best mapping ending at `body_len`, among those selected by
--- `want_auto`.
---
--- WHY THIS IS MODULE-LEVEL AND NOT A CLOSURE.
--- It lived inside `on_char`, capturing the engine instance's own codepoint
--- buffer. That made the matcher inseparable from buffer OWNERSHIP, which is the
--- single reason macOS could not adopt this core: its buffer belongs to the
--- keymap core state and is read by the keylogger, the LLM preview, the tooltip
--- and script control.
---
--- @param buf_cps table Array of UTF-8 codepoint strings (the rolling buffer).
--- @param buckets table Tail-char buckets, longest-trigger-first within each.
--- @param body_len number Index in `buf_cps` the candidate trigger must end at.
--- @param want_auto boolean Select auto_expand mappings (true) or the rest.
--- @param start_is_boundary boolean Whether the buffer's start abuts a terminator.
--- @return table|nil mapping, number|nil trigger length, string|nil effective replacement.
function M.best_match_at(buf_cps, buckets, body_len, want_auto, start_is_boundary)
	if type(buf_cps) ~= "table" or type(buckets) ~= "table" then return nil end
	if type(body_len) ~= "number" or body_len < 1 then return nil end

	local bucket = buckets[text_utils.trig_lower(buf_cps[body_len])]
	if not bucket then return nil end

	-- The bucket is sorted longest-first, so the first survivor is the longest
	-- for this path. The per-mapping decision itself is M.decide, which macOS
	-- calls directly from its own buffer — this loop is only the "which one" half.
	for _, mapping in ipairs(bucket) do
		if mapping.auto_expand == want_auto then
			local eff = M.mapping_fires(mapping, buf_cps, body_len, start_is_boundary)
			if eff then return mapping, mapping.tlen, eff end
		end
	end
	return nil
end




--- Every mapping the engine would CONSIDER at this position, not just the winner.
---
--- WHY THIS EXISTS SEPARATELY FROM best_match_at:
--- The preview bubble is not a completion list. It shows what the driver is about
--- to do, which is the only way a user can learn a trigger they half-remember and
--- the only way they can tell "nothing happened" from "something else won". So it
--- needs the losers as well as the winner, in the order the engine ranked them,
--- and it needs to know WHY each loser lost.
---
--- best_match_at returns on the first survivor by design — it is the hot path, and
--- collecting the rest there would allocate a table on every keystroke for a
--- result nothing reads when no preview is drawn.
---
--- @param buf_cps table Array of UTF-8 codepoint strings (the rolling buffer).
--- @param buckets table Tail-char buckets, longest-trigger-first within each.
--- @param body_len number Index in `buf_cps` the candidate trigger must end at.
--- @param start_is_boundary boolean Whether the buffer's start abuts a terminator.
--- @param limit number|nil Stop after this many; the panel shows a handful.
--- @return table Array of { trigger, replacement, group, section, fires, blocked }.
function M.candidates_at(buf_cps, buckets, body_len, start_is_boundary, limit)
	local out = {}
	if type(buf_cps) ~= "table" or type(buckets) ~= "table" then return out end
	if type(body_len) ~= "number" or body_len < 1 then return out end

	local bucket = buckets[text_utils.trig_lower(buf_cps[body_len])]
	if not bucket then return out end

	-- The first survivor of the auto_expand pass is the one that would actually
	-- fire; everything after it, and every non-survivor, is shown dimmed. Tracked
	-- rather than recomputed so the preview and the engine cannot disagree about
	-- which row is the live one.
	local winner_found = false

	for _, mapping in ipairs(bucket) do
		if limit and #out >= limit then break end
		local eff = M.mapping_fires(mapping, buf_cps, body_len, start_is_boundary)
		local fires = false
		if eff and mapping.auto_expand and not winner_found then
			fires = true
			winner_found = true
		end
		out[#out + 1] = {
			trigger     = mapping.trigger,
			replacement = eff or mapping.replacement,
			group       = mapping.group,
			section     = mapping.section,
			fires       = fires,
			-- Distinguished from merely losing: a mapping whose own conditions
			-- refuse it here (word boundary, case, terminator) is struck through,
			-- while one that simply ranked lower is only dimmed. The user asking
			-- "why did nothing happen" needs those to look different.
			blocked     = eff == nil,
			-- Provenance, carried since 2026-08-05 so a display path can decide
			-- what it may SHOW. This record was strictly poorer than `decide`'s,
			-- which has carried is_private all along — and the layer that most
			-- needs to know a value is a secret is the one that puts it on screen.
			-- `field` names the personal_info.toml field a value was built from,
			-- and is nil for everything else; _shared/modules/personal_info/
			-- fields.toml says which of those are masked in a preview.
			is_private  = mapping.is_private,
			field       = mapping.field,
		}
	end

	return out
end




-- =========================================
-- =========================================
-- ======= 5/ Engine Instance ==============
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
	-- Whether the buffer's own start abuts a known word terminator, which decides
	-- an is_word trigger that fills the whole buffer. macOS and AutoHotkey both
	-- carry this flag; this engine did not, and skipped the check instead — so a
	-- trigger occupying the entire buffer fired here and was refused there.
	-- True after a reset because a reset happens at a boundary (focus change,
	-- Escape, a final_result expansion); false once the rolling window has evicted
	-- a codepoint, because the buffer then starts in the middle of the user's text
	-- and nothing here knows what preceded it.
	local _start_is_boundary = true

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
				-- The section inside that group, carried since 2026-08-05. It was
				-- dropped here, so every consumer asking the delay/colour cascade
				-- about a match could only ever name the CATEGORY — the per-section
				-- rung was unreachable from the engine no matter what the settings
				-- window stored. That silently affected two things at once: the
				-- expansion-delay gate on the keystroke path, and the preview's
				-- per-section "hide the bubble" override.
				section      = source.section,
				-- Provenance, carried since 2026-08-05. This record is a WHITELIST —
				-- anything the loader does not copy is gone by the time a consumer
				-- sees a match — and both of these were being dropped here, one layer
				-- below the place they were needed. `is_private` says the payload may
				-- not be persisted or logged; `field` names the personal_info.toml
				-- field it came from, which is what lets a preview ask
				-- _shared/modules/personal_info/fields.toml whether it may be SHOWN.
				-- The two answer different questions and neither implies the other:
				-- the phone number is private and unmasked.
				is_private   = source.is_private == true,
				field        = source.field,
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
			-- The start is no longer the start of anything the user typed.
			_start_is_boundary = false
		end

		Logger.debug(LOG, "on_char('%s'): buffer %d codepoint(s).", ch, #_buf_cps)

		local buf_len = #_buf_cps

		-- Delegates to the module-level matcher rather than carrying its own copy.
		-- This body used to be a closure over `_buf_cps`, which is precisely what
		-- made the matcher inseparable from buffer ownership and blocked the macOS
		-- adoption. Two copies of one search is also how a sibling gets forgotten,
		-- which this repository has paid for more than once.
		local function best_match(body_len, want_auto)
			return M.best_match_at(_buf_cps, _buckets, body_len, want_auto, _start_is_boundary)
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
			-- Carried alongside the group since 2026-08-05. The Linux daemon's
			-- expansion-delay gate already asked the cascade for
			-- `resolve(result.group, result.section)`, and this key was not here — so
			-- it always resolved at the CATEGORY level and a per-section delay, the
			-- third rung of five, could never take effect.
			section            = mapping.section,
			-- The mapping's payload is PII and must not be persisted or logged in
			-- clear. This travels with the RESULT rather than being looked up again
			-- by the caller because the caller no longer holds the mapping: by the
			-- time it decides what to record, all it has is this table. macOS learnt
			-- the same thing — see expander.lua, which threads the flag through every
			-- sink rather than re-deriving it.
			is_private         = mapping.is_private,
		}
	end

	--- Clears the rolling typing buffer (e.g., on focus change or Escape key).
	function engine:reset()
		_buf_cps = {}
		-- A reset happens at a boundary — focus change, Escape, a final_result
		-- expansion — so what follows genuinely starts a word.
		_start_is_boundary = true
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
			_start_is_boundary = false
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

	--- The mappings the engine is currently considering, for the preview bubble.
	---
	--- Reads the instance's own buffer and boundary state so a caller does not
	--- have to reconstruct either — reconstructing `_start_is_boundary` outside is
	--- exactly how a preview ends up disagreeing with the engine about whether a
	--- trigger can fire.
	--- @param limit number|nil Stop after this many candidates.
	--- @return table Array of { trigger, replacement, group, section, fires, blocked }.
	function engine:candidates(limit)
		return M.candidates_at(_buf_cps, _buckets, #_buf_cps, _start_is_boundary, limit)
	end

	return engine
end

return M
