--- drivers/hammerspoon/_generated/registry.lua
--- AUTO-GENERATED — do not edit manually.
--- Source: static/ergopti_plus/shared/domain/registry.spec.js
--- Run: npm run codegen:registry:hs

--- ==============================================================================
--- MODULE: Registry (Generated — Hammerspoon driver)
--- DESCRIPTION:
--- Cross-driver, pure Lua 5.3+ implementation of the Registry domain contract.
--- Maintains a tail-char-bucketed index of all known trigger→replacement
--- mappings. Supports group lifecycle (enable/disable) and O(1) tail-char
--- lookups for the per-keystroke hot path.
---
--- FEATURES & RATIONALE:
--- 1. Tail-char bucketing: each mapping is indexed by its last UTF-8
---    codepoint so the hot path only visits candidates that can match.
--- 2. Group lifecycle: disabling a group removes its entries from the live
---    index without destroying them; re-enabling restores them atomically.
--- 3. Longest-first ordering: within each bucket, mappings are sorted by
---    trigger length descending, then group_order, then seq, so the first
---    candidate tested is always the longest possible match.
--- ==============================================================================

local M = {}



--- ============================
--- ============================
--- ======= 1/ Constants =======
--- ============================
--- ============================

--- Default group name assigned when opts.group is not provided.
local DEFAULT_GROUP       = "default"

--- Default group_order used when the group has no explicit order assigned.
--- A high sentinel keeps anonymous groups after explicitly ordered ones.
local DEFAULT_GROUP_ORDER = 9999



--- ================================
--- ================================
--- ======= 2/ Private State =======
--- ================================
--- ================================

--- Live bucket index: maps tail_char → sorted array of active Mapping objects.
local _mappings_by_tail_char = {}

--- Full store (active + disabled) keyed by group → array of Mapping objects.
local _store_by_group = {}

--- Set of currently disabled group names (group_name → true).
local _disabled_groups = {}

--- Monotonically increasing insertion counter, used as tiebreaker.
local _seq = 0

--- Per-group insertion order counter, incremented the first time a group is seen.
local _group_order_counter = 0

--- Map from group name → group_order value, populated lazily on first add().
local _group_order_map = {}



--- ===================================
--- ===================================
--- ======= 3/ Internal Helpers =======
--- ===================================
--- ===================================

--- =====================================
--- ===== 3.1) UTF-8 tail codepoint =====
--- =====================================

--- Returns the last UTF-8 codepoint of string s.
--- Falls back to the raw last byte when utf8.offset fails (malformed input).
--- @param s string
--- @return string
local function _tail_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, offset = pcall(utf8.offset, s, -1)
	if ok and offset then return s:sub(offset) end
	-- Malformed UTF-8: fall back to single byte at the end
	return s:sub(-1)
end


--- =====================================
--- ===== 3.2) Mapping construction =====
--- =====================================

--- Builds a Mapping object from the supplied arguments.
--- @param trigger string
--- @param repl    string
--- @param opts    table
--- @param seq     number
--- @param group_order number
--- @return table
local function _build_mapping(trigger, repl, opts, seq, group_order)
	local tail = _tail_codepoint(trigger)
	local star_base       = trigger:match("^(.-)" .. string.char(0xE2, 0x98, 0x85) .. "?$") or trigger
	-- Determine byte length of star_base safely
	local star_base_bytes = #star_base
	local star_base_tail  = _tail_codepoint(star_base)
	return {
		trigger         = trigger,
		repl            = repl,
		plain_repl      = repl,   -- Caller may override with pre-resolved value
		is_word         = opts.is_word      or false,
		auto            = opts.auto         or false,
		seq             = seq,
		tlen            = utf8.len(trigger) or #trigger,
		trigger_bytes   = #trigger,
		tail_char       = tail,
		has_magic       = opts.has_magic    or false,
		star_base       = star_base,
		star_base_bytes = star_base_bytes,
		star_base_tail  = star_base_tail,
		group           = opts.group        or DEFAULT_GROUP,
		group_order     = group_order,
		final_result    = opts.final_result or false,
		color           = opts.color        or nil,
	}
end


--- ================================
--- ===== 3.3) Sort comparator =====
--- ================================

--- Comparison function for the per-bucket sort.
--- Order: longest tlen first, then lowest group_order, then lowest seq.
--- @param a table
--- @param b table
--- @return boolean
local function _mapping_cmp(a, b)
	if a.tlen ~= b.tlen then return a.tlen > b.tlen end
	if a.group_order ~= b.group_order then return a.group_order < b.group_order end
	return a.seq < b.seq
end


--- =================================
--- ===== 3.4) Bucket insertion =====
--- =================================

--- Inserts a mapping into the live tail-char bucket and re-sorts it.
--- @param mapping table
local function _bucket_insert(mapping)
	local tc = mapping.tail_char
	if not _mappings_by_tail_char[tc] then
		_mappings_by_tail_char[tc] = {}
	end
	table.insert(_mappings_by_tail_char[tc], mapping)
	table.sort(_mappings_by_tail_char[tc], _mapping_cmp)
end

--- Removes a mapping from the live tail-char bucket.
--- @param mapping table
local function _bucket_remove(mapping)
	local bucket = _mappings_by_tail_char[mapping.tail_char]
	if not bucket then return end
	for i = #bucket, 1, -1 do
		if bucket[i] == mapping then
			table.remove(bucket, i)
			return
		end
	end
end



--- ================================
--- ================================
--- ======= 4/ Port Contract =======
--- ================================
--- ================================

--- ======================
--- ===== 4.1) M.add =====
--- ======================

--- Registers a new mapping in the registry.
--- Duplicate triggers within the same group are logged and skipped.
--- @param trigger string  The hotstring trigger text.
--- @param repl    string  The raw replacement text.
--- @param opts    table   Optional fields: is_word, auto, has_magic,
---                        final_result, group, color, plain_repl, group_order.
--- @return table|nil The created Mapping object, or nil on duplicate.
function M.add(trigger, repl, opts)
	opts = opts or {}
	local group = opts.group or DEFAULT_GROUP

	-- Assign a stable group_order the first time a group is seen
	if not _group_order_map[group] then
		-- Caller may supply an explicit rank (e.g. from a config load-order)
		_group_order_map[group] = opts.group_order
			or (function()
				_group_order_counter = _group_order_counter + 1
				return _group_order_counter
			end)()
	end
	local group_order = _group_order_map[group]

	-- Duplicate check inside the group
	local existing = _store_by_group[group]
	if existing then
		for _, m in ipairs(existing) do
			if m.trigger == trigger then
				print(string.format("[registry] Duplicate trigger '%s' in group '%s' — skipping.",
					trigger, group))
				return nil
			end
		end
	end

	_seq = _seq + 1

	-- Allow caller to override plain_repl with a pre-resolved value
	local mapping = _build_mapping(trigger, repl, opts, _seq, group_order)
	if opts.plain_repl then mapping.plain_repl = opts.plain_repl end

	-- Persist into the full store
	if not _store_by_group[group] then _store_by_group[group] = {} end
	table.insert(_store_by_group[group], mapping)

	-- Insert into live index only when the group is not disabled
	if not _disabled_groups[group] then
		_bucket_insert(mapping)
	end

	return mapping
end


--- ====================================
--- ===== 4.2) M.mappings_for_tail =====
--- ====================================

--- Returns all active mappings whose trigger ends with tail_char.
--- The returned array is sorted: longest trigger first, then group_order,
--- then seq. Callers MUST NOT mutate the returned table.
--- @param tail_char string  A single UTF-8 codepoint.
--- @return table
function M.mappings_for_tail(tail_char)
	return _mappings_by_tail_char[tail_char] or {}
end


--- ===============================
--- ===== 4.3) M.enable_group =====
--- ===============================

--- Adds all mappings in the named group back to the live index.
--- No-op when the group is already enabled or does not exist.
--- @param name string
function M.enable_group(name)
	if not _disabled_groups[name] then return end
	_disabled_groups[name] = nil
	local group_mappings = _store_by_group[name]
	if not group_mappings then return end
	for _, mapping in ipairs(group_mappings) do
		_bucket_insert(mapping)
	end
end


--- ================================
--- ===== 4.4) M.disable_group =====
--- ================================

--- Removes all mappings in the named group from the live index.
--- The mappings remain in the full store so enable_group() can restore them.
--- No-op when the group is already disabled or does not exist.
--- @param name string
function M.disable_group(name)
	if _disabled_groups[name] then return end
	_disabled_groups[name] = true
	local group_mappings = _store_by_group[name]
	if not group_mappings then return end
	for _, mapping in ipairs(group_mappings) do
		_bucket_remove(mapping)
	end
end


--- ========================
--- ===== 4.5) M.clear =====
--- ========================

--- Removes all mappings and resets the registry to its initial empty state.
function M.clear()
	_mappings_by_tail_char = {}
	_store_by_group        = {}
	_disabled_groups       = {}
	_group_order_map       = {}
	_group_order_counter   = 0
	_seq                   = 0
end


--- =======================
--- ===== 4.6) M.size =====
--- =======================

--- Returns the total number of active (non-disabled) mappings.
--- @return number
function M.size()
	local n = 0
	for _, bucket in pairs(_mappings_by_tail_char) do
		n = n + #bucket
	end
	return n
end



--- ================================
--- ================================
--- ======= 5/ Introspection =======
--- ================================
--- ================================

--- Returns the raw full store (group → mappings array). Read-only.
--- Intended for testing and diagnostics — do not mutate.
--- @return table
function M.store()
	return _store_by_group
end

--- Returns true when the named group is currently disabled.
--- @param name string
--- @return boolean
function M.is_group_disabled(name)
	return _disabled_groups[name] == true
end


return M
