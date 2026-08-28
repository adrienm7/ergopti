--- modules/keymap/registry.lua

--- ==============================================================================
--- MODULE: Keymap Registry
--- DESCRIPTION:
--- Handles the storage, sorting, and lookup of hotstring mappings, groups,
--- terminators, and sections. All persistent enable/disable state is stored
--- in hs.settings so it survives Hammerspoon reloads without writing to disk.
---
--- FEATURES & RATIONALE:
--- 1. Data Isolation: Keeps heavy lookup tables and file-loading logic out of
---    the main event loop in init.lua.
--- 2. Group Forwarding: Delegates file-loading and group-lifecycle calls to
---    registry_groups.lua via a shared CoreState reference.
--- 3. Smart Casing: Auto-generates lowercase, Title Case, and UPPERCASE
---    variants for every hotstring so the expansion matches the user's casing.
--- ==============================================================================

local M = {}

local hs          = hs
local text_utils  = require("infra.text_utils")
-- The collision cascade is shared with the Linux driver rather than defined here:
-- it existed in two Lua copies and one AutoHotkey copy, and the Linux driver had
-- none, so the same pair of colliding entries elected different winners per OS.
local HotstringPriority = require("hotstring_priority")
local km_utils    = require("modules.keymap.utils")
local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local Terminators = require("modules.keymap.terminators")
local Groups      = require("modules.keymap.registry_groups")
local RI          = require("modules.keymap.registry_index")

-- Merge group-loader forwards and section-management surface into M at load time.
-- RI.setup(core_state) is called from M.init() to wire up _state for the index functions.
for k, v in pairs(RI) do M[k] = v end

local LOG    = "keymap.registry"
local _state = nil  -- Injected via M.init(); required before all public functions.

-- Deferred-sort machinery. When _sort_deferred is true, sort_mappings() becomes
-- a no-op that only sets _sort_pending; flush_sort() then performs exactly one
-- final sort. Used at startup so the 6 TOML loads sort only once together.
-- classify_trigger memo, keyed by query string. Declared above every function
-- that touches it. Dropped by sort_mappings, which is the one funnel every
-- registration, removal and group toggle passes through.
local _classify_cache = {}

local _sort_deferred = false
local _sort_pending  = false
local CANONICAL_MAGIC_KEY = utf8.char(0x2605)


--- Guard: verifies that M.init() was called before any public function that
--- accesses _state. Logs an error and returns false when the guard fails.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True if _state is ready, false otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

-- Collision priority by hotstring SOURCE. Both drivers break a same-length
-- trigger collision identically: higher priority wins. Personal hotstrings
-- outrank "ext." packages, which outrank bundled common ones. The cascade above
-- these defaults (individual > section > file) is resolved by the loader before
-- M.add; these are the final fallback.
-- SINGLE SOURCE OF TRUTH: _shared/modules/hotstrings/priority.json, LOADED at
-- module-init time (fail-fast: a missing or malformed file logs ERROR and falls
-- back to the hardcoded tier values). The AHK driver still mirrors the same
-- values (HSE_PRIORITY_*), locked by tools/test/test-priority-parity.cjs.
local PRIORITY_COMMON   = 10
local PRIORITY_PACKAGE  = 30
local PRIORITY_PERSONAL = 50

-- Load the canonical priority tiers from the shared JSON at module-init time.
-- On success the literals above are overwritten; on failure (missing file,
-- bad JSON, missing key) the hardcoded fallbacks stay and an ERROR is logged.
do
	local function _load_priority_tiers()
		local prio_path = Paths.shared("modules/hotstrings/priority.json")
		if not prio_path then
			Logger.error(LOG, "priority.json: Paths.shared returned nil — keeping hardcoded tiers.")
			return
		end
		local fh, err = io.open(prio_path, "r")
		if not fh then
			Logger.error(LOG, "priority.json: cannot open %q: %s — keeping hardcoded tiers.", prio_path, err or "unknown error")
			return
		end
		local raw = fh:read("*a")
		fh:close()
		local ok, data = pcall(hs.json.decode, raw)
		if not ok or type(data) ~= "table" then
			Logger.error(LOG, "priority.json: JSON parse failed — keeping hardcoded tiers.")
			return
		end
		if type(data.common)   == "number" then PRIORITY_COMMON   = data.common   end
		if type(data.package)  == "number" then PRIORITY_PACKAGE  = data.package  end
		if type(data.personal) == "number" then PRIORITY_PERSONAL = data.personal end
		Logger.debug(LOG, "priority.json loaded: common=%d, package=%d, personal=%d.",
			PRIORITY_COMMON, PRIORITY_PACKAGE, PRIORITY_PERSONAL)
	end
	_load_priority_tiers()
end

--- Source-default priority for a category name.
--- Mirrors the Windows _HSE_SourcePriority tiers. The macOS loader names the
--- user's extra extension files "personal_ext_<stem>" (init.lua), which is the
--- platform analog of Windows "ext.<id>" packages — both map to the PACKAGE
--- tier so the documented order personal (50) > extension (30) > common (10)
--- holds identically on both drivers. Without the personal_ext_ branch these
--- groups silently fell to common (10) here while Windows scored them 30.
--- @param category string|nil Category (e.g. "personal", "custom", "personal_ext_demo", "ext.demo", "rolls").
--- @return integer The source-default priority (personal 50 / package 30 / common 10).
local function source_priority(category)
	return HotstringPriority.source_priority(category, {
		common   = PRIORITY_COMMON,
		package  = PRIORITY_PACKAGE,
		personal = PRIORITY_PERSONAL,
	})
end

--- Resolve the effective collision priority through the cascade
--- individual > section > file > source default. The first numeric level wins.
--- @param individual number|nil Per-hotstring priority (from the TOML entry).
--- @param section number|nil Section-level priority (from [_meta.section_priorities]).
--- @param file number|nil File-level priority (from [_meta.priority]).
--- @param category string|nil Category name, for the source-default fallback.
--- @return integer The resolved priority.
local function resolve_priority(individual, section, file, category)
	return HotstringPriority.resolve(individual, section, file, category, {
		common   = PRIORITY_COMMON,
		package  = PRIORITY_PACKAGE,
		personal = PRIORITY_PERSONAL,
	})
end

-- Exposed for the loader cascade and unit tests.
M.PRIORITY_COMMON   = PRIORITY_COMMON
M.PRIORITY_PACKAGE  = PRIORITY_PACKAGE
M.PRIORITY_PERSONAL = PRIORITY_PERSONAL
M.source_priority   = source_priority
M.resolve_priority  = resolve_priority


--- Returns the last UTF-8 codepoint of a string, used to bucket mappings by
--- tail character for O(1) lookup on keystroke. Falls back to the last byte
--- on malformed UTF-8 so the resulting index is always non-empty.
--- @param s string The input string.
--- @return string The last UTF-8 character, or "" when s is empty.
local function tail_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, off = pcall(utf8.offset, s, -1)
	if ok and off then return s:sub(off) end
	return s:sub(-1)
end

--- Returns the first UTF-8 codepoint of a string, the mirror of tail_codepoint
--- and used to bucket mappings by first character. Written with utf8.offset
--- rather than a byte-class pattern for the same reason its twin is: the pattern
--- form carries four numeric escapes that any tool rewriting this file has to
--- preserve byte for byte, and one that does not produces a pattern that still
--- compiles and matches the wrong thing.
--- @param s string The input string.
--- @return string The first UTF-8 character, or "" when s is empty.
local function first_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, off = pcall(utf8.offset, s, 2)
	if ok and off then return s:sub(1, off - 1) end
	return s:sub(1, 1)
end

--- True when the source trigger explicitly carries the canonical magic marker.
--- This is ownership provenance captured before runtime-key substitution.
--- @param t string The source trigger before substitution.
--- @return boolean
local function owns_canonical_magic(t)
	return #t >= #CANONICAL_MAGIC_KEY
		and t:sub(-#CANONICAL_MAGIC_KEY) == CANONICAL_MAGIC_KEY
end

--- True when any codepoint of the trigger is a "shift-symbol" — a char whose
--- uppercase form is NOT a simple case fold but a DIFFERENT character (or set of
--- characters): the comma, apostrophe, and period, whose Ergopti Shift forms are
--- nbsp/nnbsp + ";"/":"/"?" (see text_utils.UPPER_TRIGGERS, table-valued entries).
--- These cannot use the case-conform fast path and keep the explicit-variant path.
--- @param t string The trigger to inspect.
--- @return boolean
local function trigger_has_shift_symbol(t)
	for c in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if type(text_utils.UPPER_TRIGGERS[c]) == "table" then return true end
	end
	return false
end

--- @class Mapping
--- Single hotstring entry stored in _state.mappings. Every field is populated
--- once in add_raw() so the per-keystroke hot path (expander + llm_bridge
--- preview) does no allocation and no string math on already-known metadata.
---
--- @field trigger             string  UTF-8 hotstring the user types.
--- @field repl                string  Raw replacement, possibly containing tokens.
--- @field plain_repl          string  Replacement with tokens resolved to literal text; precomputed to skip tokens_from_repl() per keystroke.
--- @field is_word             boolean True when the trigger must match only at a word boundary.
--- @field auto                boolean True for auto-expansion triggers (fire without a terminator).
--- @field seq                 integer Monotonic counter assigned at insertion; used as a stable tiebreaker in the sort.
--- @field tlen                integer UTF-8 codepoint length of `trigger`.
--- @field trigger_bytes       integer Byte length of `trigger`; replaces repeated `#trigger` calls in the hot path.
--- @field tail_char           string  Last UTF-8 codepoint of `trigger`; keys into _state.mappings_by_tail_char.
--- @field match_mode          string  One of "conform" (single lowercase entry standing in for the lower/Title/UPPER trio, replacement re-cased at fire time), "fold" (folded compare, replacement emitted verbatim) or "exact" (only the casing written matches). Same three values, same spelling, as the shared matcher core — the shared firing predicate reads this field.
--- @field final_result        boolean True when the replacement is a finalized string (skip further substitution passes).
--- @field has_magic           boolean True when `trigger` ends with the magic key.
--- @field star_base           string|nil When has_magic, `trigger` minus the trailing magic key; nil otherwise.
--- @field star_base_bytes     integer|nil Byte length of `star_base`; nil when not magic.
--- @field star_base_tail_char string|nil Last UTF-8 codepoint of `star_base`; keys into _state.mappings_by_star_tail_char.
--- @field group               string|nil Name of the owning group, when registered inside a load_file/load_toml scope.
--- @field group_order         integer Load-order rank of the owning group; tiebreaker after length and priority.
--- @field priority            integer Collision priority (higher wins) — the first sort tiebreaker after trigger length. Resolved by the loader cascade (individual > section > file > source default 10/30/50); defaults to the common source value.





-- ==============================
-- ==============================
-- ======= 1/ Terminators =======
-- ==============================
-- ==============================

-- The catalogue, the O(1) lookup sets, and the enable/disable API all live in
-- modules/keymap/terminators.lua — see that module for the full implementation
-- and the rationale behind the hot-path caches. Registry re-exports the public
-- surface under its historical names so the menu and expander callers keep
-- working unchanged.

M.TERMINATOR_DEFS          = Terminators.TERMINATOR_DEFS
M.is_terminator            = Terminators.is_terminator
M.terminator_is_consumed   = Terminators.terminator_is_consumed
M.set_terminator_enabled   = Terminators.set_terminator_enabled
M.set_terminators_enabled  = Terminators.set_terminators_enabled
M.is_terminator_enabled    = Terminators.is_terminator_enabled
M.get_terminator_defs      = Terminators.get_terminator_defs
M.validate_custom_terminator = Terminators.validate_custom_terminator
M.add_custom_terminator    = Terminators.add_custom_terminator
M.remove_custom_terminator = Terminators.remove_custom_terminator





-- ======================================
-- ======================================
-- ======= 2/ Database Management =======
-- ======================================
-- ======================================

--- Rebuilds the O(1) lookup dictionary from the flat mappings list.
--- Must be called after any structural change to _state.mappings.
local function rebuild_lookup()
	if not _state then return end
	_state.mappings_lookup = {}
	for _, m in ipairs(_state.mappings) do
		-- Key must match add_raw's exactly, group segment included, so a rebuilt
		-- index keeps cross-source same-trigger entries distinct (see add_raw).
		local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto) .. "\0" .. (m.group or "")
		_state.mappings_lookup[k] = m
	end
end

--- Rebuilds the per-tail-char bucket indexes from the (already sorted)
--- _state.mappings list. Each mapping appears in mappings_by_tail_char
--- under its last UTF-8 codepoint; has_magic mappings additionally appear
--- in mappings_by_star_tail_char under their star_base's last codepoint. A
--- fourth narrow list retains ordinary auto mappings whose literal suffix became
--- the magic key after a runtime key change; they keep their ordinary timing
--- semantics without forcing the hot path to rescan the full magic-key bucket.
---
--- Buckets preserve the insertion order, which matches the sort order of
--- _state.mappings (longest trigger first). Callers iterate a single bucket
--- per keystroke instead of the full list, collapsing the hot-path scan
--- from ~10-15k entries to a handful.
local function rebuild_tail_indexes()
	if not _state then return end
	local tail_idx = {}
	local star_idx = {}
	local literal_magic_idx = {}
	local magic = type(_state.magic_key) == "string" and _state.magic_key or ""
	local magic_tail = magic ~= "" and text_utils.trig_lower(tail_codepoint(magic)) or nil
	-- Mappings bucketed by the FIRST codepoint of their trigger. classify_trigger
	-- answers "is `str` a prefix of some trigger?", which no existing index could
	-- serve: the tail buckets answer the other two questions (a trigger that
	-- EQUALS or ENDS WITH `str` shares its last codepoint) but say nothing about
	-- what a trigger starts with. Built here rather than in a second pass so the
	-- three indexes can never describe different corpora.
	local first_idx = {}
	for registry_rank, m in ipairs(_state.mappings) do
		-- Rank is assigned by the canonical registry sort and lets the resolver
		-- merge candidates coming from two independent O(1) indexes without
		-- duplicating this module's collision comparator.
		m.registry_rank = registry_rank
		-- tail_char is already Unicode-lowercased (trig_lower) at add_raw() time, so
		-- it is used directly as the bucket key. The expander's hot path queries the
		-- same lowercase key via mappings_for_tail (also trig_lower), so an accented
		-- uppercase tail typed by the user lands in the same bucket as registration.
		local tc = m.tail_char
		local bucket = tail_idx[tc]
		if not bucket then
			bucket = {}
			tail_idx[tc] = bucket
		end
		bucket[#bucket + 1] = m
		-- Same fold as the tail key, for the same reason: the query side lowercases
		-- what the user typed, so registration must too or an uppercase first letter
		-- probes an empty bucket.
		local fc = m.first_char
		if fc then
			local fbucket = first_idx[fc]
			if not fbucket then
				fbucket = {}
				first_idx[fc] = fbucket
			end
			fbucket[#fbucket + 1] = m
		end
		if m.has_magic and m.star_base_tail_char ~= nil then
			local sc = m.star_base_tail_char
			local sbucket = star_idx[sc]
			if not sbucket then
				sbucket = {}
				star_idx[sc] = sbucket
			end
			sbucket[#sbucket + 1] = m
		elseif m.auto and magic_tail ~= nil and tc == magic_tail
		then
			-- Mirror the star-base index: before the user presses magic, only
			-- mappings whose body shares the current buffer's folded tail can match.
			-- Removing the final codepoint (not #magic bytes) preserves fold-mode
			-- literals such as stored `litA` with configured magic `a`.
			local ok_base, base_offset = pcall(utf8.offset, m.trigger, -1)
			local base = (ok_base and base_offset) and m.trigger:sub(1, base_offset - 1) or ""
			local base_tail = base == "" and "" or text_utils.trig_lower(tail_codepoint(base))
			local lbucket = literal_magic_idx[base_tail]
			if not lbucket then
				lbucket = {}
				literal_magic_idx[base_tail] = lbucket
			end
			lbucket[#lbucket + 1] = m
		end
	end
	_state.mappings_by_tail_char      = tail_idx
	_state.mappings_by_star_tail_char = star_idx
	_state.mappings_by_first_char     = first_idx
	_state.mappings_by_literal_magic_tail = literal_magic_idx
end


--- Sorts the mappings list: longest trigger first, then word-boundary, then insertion order.
--- Longer triggers must be tested before shorter prefixes to prevent premature matches.
--- While a defer_sort() is active, the actual sort is postponed until flush_sort().
--- Rebuilds the tail-char bucket indexes at the end so they stay in sync.
function M.sort_mappings()
	if not require_state("sort_mappings") then return end
	-- Dropped BEFORE the deferral check: a deferred sort still means the corpus
	-- has changed, and the memo must not survive that even if the sort itself
	-- is coalesced to later.
	M.drop_classify_cache()
	if _sort_deferred then
		_sort_pending = true
		return
	end
	Logger.trace(LOG, "Sorting %d mapping(s)…", #_state.mappings)
	table.sort(_state.mappings, function(a, b)
		if a.tlen ~= b.tlen then return a.tlen > b.tlen end
		-- Explicit collision priority (higher wins) sits right after length so a
		-- user can make a hotstring win regardless of load order — same tie-break
		-- position as the AHK engine. Equal priority falls through to the original
		-- word-boundary / group-order / seq tiebreakers, so behaviour is unchanged
		-- wherever priorities are equal.
		local ap = a.priority or PRIORITY_COMMON
		local bp = b.priority or PRIORITY_COMMON
		if ap ~= bp then return ap > bp end
		if a.is_word ~= b.is_word then return a.is_word end
		-- Stable cross-reload priority: groups keep their original insertion
		-- order across disable/enable cycles, so two same-length triggers
		-- cannot flip relative priority after a hot-reload (B3.6). `seq`
		-- within a group stays monotonic by design.
		local ao = a.group_order or 0
		local bo = b.group_order or 0
		if ao ~= bo then return ao < bo end
		return a.seq < b.seq
	end)
	rebuild_tail_indexes()
	Logger.done(LOG, "Mappings sorted.")
end

--- Returns the bucket of mappings whose trigger ends with `tail_char`, in
--- sort order (longest trigger first). Returns nil when the bucket is empty
--- or the registry is not yet initialized; callers must handle that case.
--- @param tail_char string Single-codepoint UTF-8 string.
--- @return table|nil Array of mapping entries, or nil.
function M.mappings_for_tail(tail_char)
	if not _state or type(tail_char) ~= "string" then return nil end
	-- Buckets are keyed by the trigger's last codepoint Unicode-LOWERCASED (see
	-- add_raw's tail_char). The lookup MUST apply the same fold, otherwise an
	-- uppercase last char probes an empty bucket and the auto-expansion never fires.
	-- trig_lower (not ASCII :lower()) covers accented capitals — "Ê" → "ê" — so a
	-- case-conform entry registered only in lowercase still matches UPPERCASE input.
	return _state.mappings_by_tail_char[text_utils.trig_lower(tail_char)]
end

--- Returns the bucket of has_magic mappings whose star_base ends with
--- `tail_char`, in sort order. Used by the LLM preview's star_base match path.
--- @param tail_char string Single-codepoint UTF-8 string.
--- @return table|nil Array of mapping entries, or nil.
function M.mappings_for_star_tail(tail_char)
	if not _state or type(tail_char) ~= "string" then return nil end
	-- star_base follows the same match-mode semantics as the full trigger. The
	-- registration side stores a folded tail key, so the preview/resolver query
	-- must fold too; otherwise a fold-mode `abc★` fires for `ABC★` while the
	-- prospective lookup probes the raw `C` bucket and finds nothing.
	return _state.mappings_by_star_tail_char[text_utils.trig_lower(tail_char)]
end

--- Returns ordinary auto mappings whose literal trigger currently ends with the
--- configured magic key and whose body shares `tail_char`, in canonical order.
--- @param tail_char string Folded at lookup like every other tail index.
--- @return table|nil Array of mapping entries, or nil.
function M.mappings_for_literal_magic_tail(tail_char)
	if not _state or type(tail_char) ~= "string" then return nil end
	local index = _state.mappings_by_literal_magic_tail
	return index and index[text_utils.trig_lower(tail_char)] or nil
end

--- Returns all three trigger-membership flags in a single O(N) pass.
--- Replaces the former triple-scan pattern (has_exact_trigger + has_trigger_prefix
--- + has_trigger_suffix) that iterated _state.mappings three times per keystroke on
--- the synchronous eventtap path when personal-info is active and the user presses
--- `@`. Early-exits the loop as soon as all three bits are known.
--- @param str string The buffer to test against all registered triggers.
--- @return boolean exact True when `str` matches a trigger exactly.
--- @return boolean prefix True when `str` is a prefix of any trigger.
--- @return boolean suffix True when `str` is a suffix of any trigger.
--- Drops the classify_trigger memo.
---
--- Every corpus mutation must call this. sort_mappings used to be the only one
--- that did, which was correct for every path that goes through it and wrong for
--- disable_group, which shrinks the corpus and rebuilds the lookup and tail
--- indexes without sorting. classify_trigger then kept answering `exact = true`
--- for mappings that no longer existed, and the dynamic @-collector reads exactly
--- that answer to decide whether a trigger is already claimed — so a stale true
--- silently suppressed collection for the rest of the session.
function M.drop_classify_cache()
	_classify_cache = {}
end

function M.classify_trigger(str)
	if not _state or type(str) ~= "string" or str == "" then
		return false, false, false
	end
	-- Memoised. This walks every registered mapping and builds two substrings per
	-- entry, inside the keyDown eventtap, to answer a question about a string that
	-- is almost always the one it was asked about a keystroke earlier. The answer
	-- is a pure function of (str, corpus), and the cache is dropped whenever the
	-- corpus changes — a memo that outlived a re-registration would answer for a
	-- mapping set that no longer exists, which is worse than the scan it replaces.
	local hit = _classify_cache[str]
	if hit then return hit[1], hit[2], hit[3] end

	local n     = #str
	local exact = false
	local pref  = false
	local suff  = false

	-- Two buckets instead of the whole corpus. A trigger that EQUALS `str`, or
	-- ENDS WITH it, necessarily shares its last codepoint; one that STARTS WITH it
	-- shares its first. Both buckets are keyed by the FOLDED codepoint and hold a
	-- superset of the candidates, so the byte-exact comparisons below still decide
	-- — the index narrows the search, it does not answer the question.
	--
	-- On a corpus of ~10-15k mappings this replaced a full scan with two substring
	-- allocations per entry, run inside the keyDown eventtap. It is memoised above,
	-- so the scan only ever ran on a miss — but the query is the whole keymap
	-- buffer plus "@", which is a different string almost every time.
	--
	-- The indexes are built by sort_mappings, so between an M.add and the next
	-- sort there is nothing to read. Rebuilding here rather than falling back to a
	-- scan keeps ONE implementation of the rule: a fallback loop would be a second
	-- answer to the same question, free to drift from this one, and it would drift
	-- silently because both would be right most of the time.
	if not _state.mappings_by_first_char or not _state.mappings_by_tail_char then
		rebuild_tail_indexes()
	end

	local tail_bucket  = _state.mappings_by_tail_char
		and _state.mappings_by_tail_char[text_utils.trig_lower(tail_codepoint(str))]
	local first_bucket = _state.mappings_by_first_char
		and _state.mappings_by_first_char[text_utils.trig_lower(first_codepoint(str))]

	if tail_bucket then
		for _, m in ipairs(tail_bucket) do
			local t = m.trigger
			if not exact and t == str           then exact = true end
			if not suff  and t:sub(-n) == str   then suff  = true end
			if exact and suff then break end
		end
	end
	if first_bucket then
		for _, m in ipairs(first_bucket) do
			if m.trigger:sub(1, n) == str then pref = true ; break end
		end
	end

	_classify_cache[str] = { exact, pref, suff }
	return exact, pref, suff
end

--- Returns true when `str` matches a registered trigger exactly.
--- Kept for backward compatibility with call sites that need a single boolean.
--- @param str string The string to test.
--- @return boolean
function M.has_exact_trigger(str)
	local exact = M.classify_trigger(str)
	return exact
end

--- Returns true when `str` is a prefix of any registered trigger.
--- @param str string The string to test.
--- @return boolean
function M.has_trigger_prefix(str)
	local _, pref = M.classify_trigger(str)
	return pref
end

--- Returns true when `str` is a suffix of any registered trigger.
--- @param str string The string to test.
--- @return boolean
function M.has_trigger_suffix(str)
	local _, _, suff = M.classify_trigger(str)
	return suff
end


--- Suspends automatic re-sorting. Every subsequent call to sort_mappings() becomes
--- a no-op that only marks a sort as pending. Paired with flush_sort() at the end
--- of a batch (e.g. the initial TOML load loop) to avoid 6+ O(N log N) passes.
function M.defer_sort()
	_sort_deferred = true
	_sort_pending  = false
	Logger.debug(LOG, "Sort deferred.")
end

--- Resumes automatic sorting and performs one final sort if one was requested
--- while sorting was deferred. Safe to call even when defer_sort() was not used.
function M.flush_sort()
	_sort_deferred = false
	if _sort_pending then
		_sort_pending = false
		M.sort_mappings()
	end
	Logger.debug(LOG, "Sort flushed.")
end

--- Registers a mapping entry with smart case-variant generation.
---
--- For case-insensitive triggers, this function registers:
---   - lowercase trigger → lowercase replacement
---   - Title Case trigger → Title Case replacement
---   - UPPERCASE trigger  → UPPERCASE replacement
---
--- For triggers starting with ",", a ";" alias is also generated.
---
--- @param trigger string The sequence to monitor.
--- @param replacement string The resulting expansion string.
--- @param opts table Optional flags: is_word, auto_expand, is_case_sensitive,
---   final_result, is_private (trigger and replacement are secrets — never logged),
---   field (the personal_info.toml field the replacement came from, so the preview
---   can ask the shared declaration how much of it may be shown).
function M.add(trigger, replacement, opts)
	if not require_state("add") then return end
	if type(trigger) ~= "string" or trigger == "" then
		Logger.error(LOG, "add: trigger must be a non-empty string (got '%s').", tostring(trigger))
		return
	end
	if type(replacement) ~= "string" then
		Logger.error(LOG, "add: replacement must be a string (got '%s').", type(replacement))
		return
	end

	opts = type(opts) == "table" and opts or {}
	local owns_magic = owns_canonical_magic(trigger) or opts.is_magic_trigger == true

	-- Substitute the canonical magic-key when a non-default trigger char is configured.
	-- The key is user-configurable through the menu, which accepts any codepoint —
	-- including "%", which Lua treats specially on the REPLACEMENT side of gsub and
	-- which raises "invalid use of '%' in replacement string". Unescaped, choosing
	-- "%" as the magic key made every add() throw during registration, so the driver
	-- came back from the post-change reload with no hotstrings at all.
	if _state.magic_key and _state.magic_key ~= CANONICAL_MAGIC_KEY then
		trigger = trigger:gsub(CANONICAL_MAGIC_KEY,
			text_utils.escape_gsub_replacement(_state.magic_key))
	end

	if owns_magic then
		local active = _state.magic_key
		if type(active) ~= "string" or active == ""
			or #trigger < #active or trigger:sub(-#active) ~= active
		then
			Logger.error(LOG, "add: is_magic_trigger requires a trigger ending in the active magic key.")
			return
		end
	end
	local is_word           = opts.is_word           == true
	local is_auto           = opts.auto_expand        == true
	-- The two case flags are ORTHOGONAL, exactly as the AutoHotkey loader treats
	-- them (hotstring_builder.ahk: is_case_sensitive picks the REGISTRAR, the "C"
	-- flag picks the comparison). is_case_sensitive alone means "register the
	-- trigger literally, generate no cased family" — matching still folds case and
	-- the replacement is emitted verbatim. Only strict makes the comparison exact.
	-- Reading the first flag as "compare exactly" is what stopped 592 shared
	-- entries — the acronym autocorrections, `"adn" = { output = "ADN" }` — from
	-- firing on any casing but the one written in the TOML.
	local is_case_sensitive = opts.is_case_sensitive  == true
	local is_strict         = opts.is_case_sensitive_strict == true
	local is_final          = opts.final_result       == true
	-- Marks a mapping whose trigger AND replacement are user secrets (the
	-- personal_info.toml phone / SSN / IBAN prefixes). The expander reads this
	-- to suppress the keylogger call and the plaintext DEBUG line that would
	-- otherwise copy both into the 14-day log and the exported metrics store
	local is_private        = opts.is_private         == true
	-- The personal_info.toml field this replacement was built from, when it has
	-- one. The preview asks the shared declaration BY NAME how much of a value may
	-- appear on screen, so a mapping that arrives without it is masked whole —
	-- safe, but wrong for the fields the declaration marks public. Generated
	-- aliases inherit it, like the section above.
	local field             = type(opts.field) == "string" and opts.field or nil
	-- Owning section name (e.g. "comma_j"), threaded through so mapping_fires can
	-- look up a per-section delay override. Generated aliases inherit it.
	local section           = type(opts.section) == "string" and opts.section or nil
	-- Resolved collision priority. The loader passes the cascade result
	-- (individual > section > file > source default); ad-hoc M.add calls and
	-- not-yet-migrated callers default to the common source value, which keeps
	-- every mapping equal — so ties still fall through to the existing
	-- word-boundary / group-order / seq tiebreakers (behaviour unchanged).
	local priority          = type(opts.priority) == "number" and opts.priority or PRIORITY_COMMON

	-- Replacements containing newlines or key directives are always "final" so
	-- the engine does not attempt to chain another expansion on top of them.
	if replacement:match("\n") or replacement:match("{Tab}") or replacement:match("{Enter}") or replacement:match("{Return}") then
		is_final = true
	end

	--- Appends or updates a single mapping entry in the database.
	--- @param t string The trigger.
	--- @param r string The replacement.
	--- @param a boolean True for auto-expand mode.
	--- @param plain_r string Precomputed plain_text(tokens_from_repl(r)). The
	---   caller computes this once per replacement variant and threads it
	---   through all space-variant calls, so we never tokenize the same
	---   replacement 3-4× at load time.
	local function add_raw(t, r, a, plain_r, conform, fold)
		-- The owning group is part of the dedup identity. Re-adding a trigger from
		-- the SAME source (a file hot-reload) updates the entry in place for
		-- idempotency, but the SAME trigger arriving from a DIFFERENT source — e.g.
		-- a personal hotstring shadowing a bundled common one — must become its own
		-- competing entry so the collision-priority sort can elect the winner. This
		-- matches the AHK engine, which keeps every registration as a distinct spec.
		-- Without the group segment the later-loaded source silently overwrote the
		-- earlier one's replacement (common loads after personal at startup), so the
		-- user's higher-priority personal hotstring lost — defeating the priority
		-- feature for the exact scenario it exists to serve.
		local current_group = _state.current_group
		local group_state = current_group and _state.groups[current_group] or nil
		local group_order = (group_state and group_state.group_order) or 0
		local match_mode = conform and "conform" or (fold and "fold" or "exact")
		local trigger_folded = fold and text_utils.trig_lower(t) or nil
		-- Precompute magic-key membership so the main event loop does not have to
		-- recompute it on every keystroke; invalidated by update_trigger_char().
		local mk        = _state.magic_key
		local mkl       = #mk
		local has_magic = owns_magic
		local star_base = has_magic and t:sub(1, #t - mkl) or nil
		local star_base_bytes = star_base and #star_base or nil
		local star_base_tail_char = star_base ~= nil
			and (star_base == "" and "" or text_utils.trig_lower(tail_codepoint(star_base)))
			or nil

		local k        = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a) .. "\0" .. (current_group or "")
		local existing = _state.mappings_lookup[k]
		if existing then
			-- Same source re-adding the trigger -> refresh every field derived from
			-- the current registration. The identity fields above are intentionally
			-- stable, but treating options as immutable retained stale priority,
			-- section, privacy, and match-mode metadata from the first occurrence.
			existing.repl                = r
			existing.plain_repl          = plain_r
			existing.is_private          = is_private
			existing.field               = field
			existing.section             = section
			existing.priority            = priority
			existing.group               = current_group
			existing.group_order         = group_order
			existing.match_mode          = match_mode
			existing.trigger_folded      = trigger_folded
			existing.final_result        = is_final
			existing.has_magic           = has_magic
			existing.star_base           = star_base
			existing.star_base_bytes     = star_base_bytes
			existing.star_base_tail_char = star_base_tail_char
			return
		end
		_state.seq_counter = _state.seq_counter + 1
		local entry = {
			trigger      = t,
			repl         = r,
			-- Precomputed once at load time; avoids tokens_from_repl() + plain_text()
			-- being called on every keystroke in update_preview() and the expander
			plain_repl   = plain_r,
			is_word      = is_word,
			is_private   = is_private,
			field        = field,
			section      = section,
			auto         = a,
			priority     = priority,
			seq          = _state.seq_counter,
			tlen         = text_utils.utf8_len(t),
			-- Byte-length cache: the main event loop compares buffer suffixes
			-- byte-by-byte, so #m.trigger is needed on every frame — caching saves
			-- one C call per mapping per keystroke
			trigger_bytes = #t,
			-- Last UTF-8 codepoint of the trigger, used later to bucket mappings
			-- by tail character so run_trigger_checks can skip any mapping whose
			-- last char does not match the just-typed character. Unicode-lowercased
			-- (trig_lower, not ASCII :lower()) so an accented uppercase tail typed by
			-- the user — "Ê" — resolves to the same bucket as the lowercase "ê"
			-- registration. This is what lets a case-conform entry (registered in
			-- lowercase only) match an UPPERCASE-typed trigger whose tail is accented.
			tail_char    = text_utils.trig_lower(tail_codepoint(t)),
			-- First codepoint, folded like tail_char. Buckets the "is this string a
			-- PREFIX of some trigger?" question, which the tail index cannot answer.
			first_char   = text_utils.trig_lower(first_codepoint(t)),
			-- The three-way match mode, resolved once at registration. It used to be
			-- two orthogonal booleans (case_conform, case_fold) — a second vocabulary
			-- for the same three outcomes the shared matcher core already names, and
			-- the shared firing predicate could read neither.
			--   "conform" — this single entry stands in for the lower/Title/UPPER
			--               trio: the expander conforms the replacement's case to the
			--               typed trigger at fire time instead of the registry
			--               pre-generating three variants.
			--   "fold"    — match with case folding but emit the replacement
			--               verbatim. An acronym entry must yield "ADN" whether the
			--               user typed "adn" or "Adn", so conforming it would be
			--               wrong in both directions.
			--   "exact"   — only the casing written matches.
			match_mode   = match_mode,
			-- Precomputed folded trigger, the canonical side of a "fold" compare.
			-- Only the typed text is folded on the hot path.
			trigger_folded = trigger_folded,
			final_result = is_final,
			has_magic    = has_magic,
			star_base    = star_base,
			-- Matching metadata for the preview path, where matches are tested
			-- against star_base rather than the full trigger
			star_base_bytes     = star_base_bytes,
			-- Empty string is a real bucket key: a bare magic-key mapping remains
			-- the shortest fallback for every magic-key press.
			star_base_tail_char = star_base_tail_char,
		}
		entry.group = current_group
		-- group_order is 0 for mappings added outside a load_file/load_toml
		-- scope (e.g. ad-hoc M.add calls with no active group), which keeps
		-- them at the head of the tiebreaker — same as before this change.
		entry.group_order = group_order
		table.insert(_state.mappings, entry)
		_state.mappings_lookup[k] = entry
	end

	--- Adds the trigger and its space-normalized variants (nbsp, nnbsp). The
	--- caller precomputes plain_r so it is not recomputed per space variant.
	--- @param t string The trigger.
	--- @param r string The replacement.
	--- @param plain_r string Precomputed plain_text of r.
	local function add_with_space_variants(t, r, plain_r, conform, fold)
		add_raw(t, r, is_auto, plain_r, conform, fold)
		-- Only generate space variants for triggers that contain spaces but do not
		-- *start* with a space (starting-space triggers are word-boundary guards).
		local starts_with_space = t:match("^[ \194\160\226\128\175]") ~= nil
		if not starts_with_space and t:match(" ") then
			add_raw((t:gsub(" ", "\194\160")),   r, is_auto, plain_r, conform, fold)  -- regular nbsp
			add_raw((t:gsub(" ", "\226\128\175")), r, is_auto, plain_r, conform, fold) -- narrow nbsp
		end
	end

	-- Tokenize+plaintext the base replacement exactly once per M.add call. The
	-- Title/UPPER replacement plain-text forms are computed lazily below, only on
	-- the explicit-variant path (the case-conform path never needs them, which is
	-- the bulk of the corpus at startup).
	-- Case variants belong to the trigger BODY, never to the configured magic
	-- action suffix. With an alphabetic key such as "a", uppercasing the whole
	-- string registered "BTWA" while the physical action is still lowercase
	-- "a", making the advertised uppercase expansion unreachable.
	local case_suffix = ""
	local case_body   = trigger
	if owns_magic then
		case_suffix = _state.magic_key
		case_body = trigger:sub(1, #trigger - #case_suffix)
	end
	local lower_body       = text_utils.trig_lower(case_body)
	local lower_trig       = lower_body .. case_suffix
	local plain_repl_base  = km_utils.plain_text(km_utils.tokens_from_repl(replacement))

	-- ── Case-conform fast path (mirrors AHK CreateCaseSensitiveHotstrings) ──────
	-- An auto (immediate), case-insensitive trigger whose replacement is plain
	-- text and whose trigger carries no shift-symbol char (',', '\'', '.') is
	-- registered as ONE lowercase entry; the expander conforms the replacement's
	-- case to the typed trigger at fire time. This collapses the lower/Title/UPPER
	-- explosion (~2119 magic-key specs → ~1000) — the dominant startup + memory
	-- cost. Triggers WITH shift-symbols keep the explicit path because their UPPER
	-- forms are DIFFERENT characters (nbsp+;/:/?) a case-fold cannot reproduce; the
	-- exclusion of has_magic keeps the case-sensitive star-preview path untouched.
	local use_conform = (not is_case_sensitive)
		and is_auto
		and (not owns_magic)
		and (plain_repl_base == replacement)
		and (not trigger_has_shift_symbol(lower_trig))

	-- Title/UPPER replacement forms are needed by BOTH the explicit-variant path
	-- and the comma-alias block further down; computed once here unless the
	-- conform fast path applies (it needs neither, which is the common case).
	local title_repl, upper_repl, plain_repl_title, plain_repl_upper
	if not use_conform then
		title_repl       = text_utils.repl_title(replacement)
		upper_repl       = text_utils.repl_upper(replacement)
		plain_repl_title = km_utils.plain_text(km_utils.tokens_from_repl(title_repl))
		plain_repl_upper = km_utils.plain_text(km_utils.tokens_from_repl(upper_repl))
	end

	if is_strict then
		-- Exact: the casing written in the TOML, and nothing else, fires.
		add_with_space_variants(trigger, replacement, plain_repl_base, false)
	elseif is_case_sensitive then
		-- Literal registration with a folding comparison. The trigger is stored AS
		-- WRITTEN — folding happens in the comparison, against a precomputed
		-- trigger_folded — because every other consumer (has_exact_trigger, the
		-- preview index, the dynamic-hotstring rules engine) looks the mapping up by
		-- the trigger it registered.
		add_with_space_variants(trigger, replacement, plain_repl_base, false, true)
	elseif use_conform then
		add_with_space_variants(lower_trig, replacement, plain_repl_base, true)
	else
		local title_trigs = {}
		for _, body in ipairs(text_utils.trig_title(lower_body)) do
			title_trigs[#title_trigs + 1] = body .. case_suffix
		end
		local upper_trigs = {}
		for _, body in ipairs(text_utils.trig_upper(lower_body)) do
			upper_trigs[#upper_trigs + 1] = body .. case_suffix
		end

		add_with_space_variants(lower_trig, replacement, plain_repl_base, false)

		for _, tt in ipairs(title_trigs) do
			if tt ~= lower_trig then add_with_space_variants(tt, title_repl, plain_repl_title, false) end
		end

		for _, ut in ipairs(upper_trigs) do
			-- Single-character body special case: when the trigger body is one
			-- char (e.g. "e★", or a plain "e"), title and upper are identical
			-- strings. Registering both would surface a phantom "EST" entry as
			-- a dimmed alternative in the multi-row tooltip — an alternative
			-- the engine could never actually fire because title already wins.
			-- The same invariant lives in the AHK prefix watcher
			-- (_AddTriggerVariants in hotstring_prefix_watcher.ahk).
			local is_title = false
			for _, tt in ipairs(title_trigs) do
				if ut == tt then is_title = true; break end
			end
			if ut ~= lower_trig and not is_title then
				add_with_space_variants(ut, upper_repl, plain_repl_upper, false)
			end
		end
	end

	-- Generate ";" and nbsp-prefixed aliases for triggers that start with ",".
	-- On the Ergopti layout ";" is in the comma layer, so both keys should fire.
	-- nbsp (U+00A0) + ";" or ":" and nnbsp (U+202F) + ";" or ":" are the shifted
	-- forms of "," on the layout — they must trigger J+vowel independently of
	-- whether nbsp/nnbsp are configured as word terminators.
	local NBSP  = "\194\160"     -- U+00A0
	local NNBSP = "\226\128\175" -- U+202F
	-- Both literal modes keep the casing they were written with; only the cased
	-- family works from the lowercase canonical.
	local first_char_src = (is_strict or is_case_sensitive) and trigger or lower_trig
	local first_char     = first_char_src:match("^[%z\1-\127\194-\244][\128-\191]*")
	if first_char == "," then
		local rest_body = lower_body:sub(#first_char + 1)
		if rest_body ~= "" or case_suffix ~= "" then
			local lower_rest = text_utils.trig_lower(rest_body) .. case_suffix
			local upper_rests = {}
			for _, body in ipairs(text_utils.trig_upper(rest_body)) do
				upper_rests[#upper_rests + 1] = body .. case_suffix
			end
			-- Plain ";" alias (original behaviour)
			add_with_space_variants(";" .. lower_rest, title_repl, plain_repl_title)
			for _, ru in ipairs(upper_rests) do
				local alias = ";" .. ru
				if alias ~= ";" .. lower_rest then
					add_with_space_variants(alias, upper_repl, plain_repl_upper)
				end
			end
			-- nbsp/nnbsp + ";" and ":" aliases — independent of terminator config
			for _, sp in ipairs({ NBSP, NNBSP }) do
				for _, punct in ipairs({ ";", ":" }) do
					local pfx = sp .. punct
					add_raw(pfx .. lower_rest, title_repl, is_auto, plain_repl_title)
					for _, ru in ipairs(upper_rests) do
						local alias = pfx .. ru
						if alias ~= pfx .. lower_rest then
							add_raw(alias, upper_repl, is_auto, plain_repl_upper)
						end
					end
				end
			end
		end
	end

    -- Log disabled because we have thousands of mappings
	-- Logger.debug(LOG, "Mapping added: '%s' → '%s'%s.",
	-- 	trigger, replacement, is_auto and " [auto]" or "")
end





-- =============================
-- =============================
-- ======= 3/ Module API =======
-- =============================
-- =============================

--- Injects the shared CoreState from keymap/init.lua.
--- Must be called exactly once before any other function in this module.
--- @param core_state table The shared state object.
--- @return boolean committed True only when the registry is ready for callers.
function M.init(core_state)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s).", type(core_state))
		return false
	end
	if _state then
		if _state == core_state then
			Logger.warn(LOG, "M.init() called more than once with the active state — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): a different state is already active — replacement refused.")
		return false
	end
	local groups_ready = Groups.init(core_state, {
		add                  = M.add,
		sort_mappings        = M.sort_mappings,
		is_section_enabled   = M.is_section_enabled,
		resolve_priority     = resolve_priority,
		rebuild_lookup       = rebuild_lookup,
		rebuild_tail_indexes = rebuild_tail_indexes,
		drop_classify_cache  = M.drop_classify_cache,
	})
	if groups_ready ~= true then
		Logger.error(LOG, "M.init(): group registry dependency initialization refused.")
		return false
	end
	if RI.setup(core_state) ~= true then
		Logger.error(LOG, "M.init(): registry index dependency initialization refused.")
		return false
	end
	_state = core_state
	Logger.debug(LOG, "Registry initialized.")
	return true
end

--- Reassigns the magic-key character across the terminator definitions AND
--- every affected mapping. Triggers whose last character was the previous
--- magic key are renamed, and every precomputed field (trigger_bytes,
--- tail_char, star_base, star_base_bytes, star_base_tail_char, tlen) is
--- recomputed so the event loop and preview scanner remain consistent.
---
--- Because trigger keys in _state.mappings_lookup embed m.trigger, the lookup
--- is rebuilt after renaming. A final sort is issued because the byte length
--- of the magic key (and therefore tlen) may have changed.
---
--- The write to _state.magic_key happens inside this function so that the
--- old value is available during the rename pass. Callers must not pre-set
--- _state.magic_key before invoking update_trigger_char.
---
--- @param char string The new trigger character.
--- @return boolean committed
function M.update_trigger_char(char)
	local valid, reason = Terminators.validate_character(char)
	if not valid then
		Logger.error(LOG, "update_trigger_char: candidate refused (%s).", tostring(reason))
		return false
	end
	if not require_state("update_trigger_char") then return false end

	local old_char = _state.magic_key
	if Terminators.update_magic_key(char) ~= true then
		Logger.error(LOG, "update_trigger_char: terminator update did not commit.")
		return false
	end

	if old_char == char then
		Logger.debug(LOG, "update_trigger_char: key unchanged ('%s') — skipping rename.", char)
		return true
	end

	Logger.start(LOG, "Renaming magic key '%s' → '%s' across %d mapping(s)…", old_char, char, #_state.mappings)

	local old_len = #old_char
	local new_len = #char
	local renamed = 0
	for _, m in ipairs(_state.mappings) do
		-- A mapping carried the old magic key iff its trigger ended with it.
		-- This check must use the OLD key (via m.trigger) before we rename, so
		-- we never rely on the stale m.has_magic flag.
		local had_magic = m.has_magic == true
		if had_magic then
			local base   = m.trigger:sub(1, #m.trigger - old_len)
			local new_tr = base .. char
			m.trigger             = new_tr
			m.trigger_bytes       = #new_tr
			-- trig_lower (not ASCII :lower()) is required here so that accented
			-- capital tails ("Ê") are lowercased to "ê" — matching the trig_lower
			-- used at add_raw() time and in mappings_for_tail bucket lookup.
			m.tail_char           = text_utils.trig_lower(tail_codepoint(new_tr))
			m.tlen                = text_utils.utf8_len(new_tr)
			m.has_magic           = true
			m.star_base           = base
			m.star_base_bytes     = #base
			m.star_base_tail_char = base == "" and ""
				or text_utils.trig_lower(tail_codepoint(base))
			renamed = renamed + 1
		else
			-- Previously non-magic mappings must not suddenly gain has_magic
			-- just because their trigger happens to end with the new key
			-- (we cannot rewrite their replacement anyway). Keep them untouched.
			m.has_magic = false
			m.star_base = nil
			m.star_base_bytes     = nil
			m.star_base_tail_char = nil
		end
	end

	_state.magic_key = char
	rebuild_lookup()
	M.sort_mappings()
	-- Byte length of the magic key may have changed (★ is 3 bytes, § is 2),
	-- so triggers shift in both byte length and tlen — resorting preserves
	-- the longest-first invariant that the event loop depends on.
	if new_len ~= old_len then
		Logger.debug(LOG, "Magic-key byte length changed (%d → %d) — lookup rebuilt and mappings re-sorted.", old_len, new_len)
	end
	Logger.success(LOG, "Magic-key rename complete (%d mapping(s) renamed).", renamed)
	return true
end

return M
