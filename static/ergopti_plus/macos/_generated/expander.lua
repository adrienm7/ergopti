--- drivers/hammerspoon/_generated/expander.lua
--- AUTO-GENERATED — do not edit manually.
--- Source: static/ergopti_plus/shared/domain/expander.spec.js
--- Run: npm run codegen:expander:hs

--- ==============================================================================
--- MODULE: Expander (Generated — Hammerspoon driver)
--- DESCRIPTION:
--- Cross-driver, pure Lua 5.3+ implementation of the Expander domain contract.
--- Receives the current typing buffer and a tail character, queries the
--- Registry for candidate mappings, selects the best match, and returns an
--- ExpansionResult descriptor. No OS-specific APIs are used.
---
--- FEATURES & RATIONALE:
--- 1. Stateless expansion decision: decide() is a pure function of
---    (buffer, tail_char, opts) — no hidden global state beyond cycle tracking.
--- 2. Word-boundary enforcement: mappings with is_word=true only fire when
---    the character immediately before the trigger is a non-word character
---    (space, punctuation) or the trigger starts at the buffer boundary.
--- 3. Magic-key cycling: cycle_next() advances through the star bucket for
---    the same trigger base; cycling state is owned exclusively by this module.
--- 4. Backspace count: trigger_bytes + 1 when the terminator was consumed.
--- ==============================================================================

local M = {}



--- ============================
--- ============================
--- ======= 1/ Constants =======
--- ============================
--- ============================

--- UTF-8 byte sequence for the U+2605 BLACK STAR magic key character.
local STAR_CHAR = string.char(0xE2, 0x98, 0x85)

--- Pattern that matches a single non-word boundary character.
--- A word char is any ASCII letter, digit, or underscore.
local WORD_CHAR_PATTERN = "[%w_]"



--- ================================
--- ================================
--- ======= 2/ Private State =======
--- ================================
--- ================================

--- Registry instance injected via M.init().
local _registry = nil

--- Cycling state: base trigger string of the last expansion, or nil.
local _cycle_base = nil

--- Cycling state: index into the star bucket that was last returned.
local _cycle_index = nil

--- Cycling state: the candidate list frozen at the time of the first expansion.
local _cycle_candidates = nil



--- ========================================
--- ========================================
--- ======= 3/ Module Initialisation =======
--- ========================================
--- ========================================

--- Guard: verifies that M.init() was called before any public function.
--- Logs an error via print and returns false on failure.
--- @param func_name string Name of the calling function.
--- @return boolean True when all dependencies are ready.
local function require_state(func_name)
	if not _registry then
		print(string.format("[expander] ERROR '%s' called before M.init() — registry not initialized.", func_name))
		return false
	end
	return true
end

--- Initialises the Expander with a Registry instance.
--- Must be called exactly once before any other public function.
--- @param registry table A Registry implementing mappings_for_tail().
function M.init(registry)
	if type(registry) ~= "table" or type(registry.mappings_for_tail) ~= "function" then
		print("[expander] ERROR M.init(): registry must expose mappings_for_tail — module non-functional.")
		return
	end
	if _registry then
		print("[expander] WARN M.init() called more than once — ignoring duplicate call.")
		return
	end
	_registry = registry
end



--- ===================================
--- ===================================
--- ======= 4/ Internal Helpers =======
--- ===================================
--- ===================================

--- ==============================
--- ===== 4.1) UTF-8 helpers =====
--- ==============================

--- Returns the last UTF-8 codepoint of string s as a byte string.
--- Falls back to the raw last byte on malformed input.
--- @param s string
--- @return string
local function _tail_cp(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, offset = pcall(utf8.offset, s, -1)
	if ok and offset then return s:sub(offset) end
	return s:sub(-1)
end

--- Returns the number of UTF-8 codepoints in s (falls back to byte length).
--- @param s string
--- @return number
local function _utf8_len(s)
	return utf8.len(s) or #s
end


--- ====================================
--- ===== 4.2) Word boundary check =====
--- ====================================

--- Returns true when the character immediately before the trigger position in
--- buffer is a non-word character, or when the trigger starts at the buffer
--- boundary (no preceding character). Used to enforce is_word=true semantics.
--- @param buffer string  The full typing buffer.
--- @param trigger_bytes number  Byte length of the matched trigger.
--- @return boolean
local function _word_boundary_ok(buffer, trigger_bytes)
	local pre_end = #buffer - trigger_bytes
	if pre_end <= 0 then
		-- Trigger spans the entire buffer — start-of-buffer counts as a boundary
		return true
	end
	-- Find the last codepoint before the trigger start
	local pre_str = buffer:sub(1, pre_end)
	local last_cp = _tail_cp(pre_str)
	-- A non-word character satisfies the boundary requirement
	return last_cp:match(WORD_CHAR_PATTERN) == nil
end


--- ======================================
--- ===== 4.3) Build ExpansionResult =====
--- ======================================

--- Constructs an ExpansionResult table from a candidate mapping and call context.
--- @param mapping table  The matched Mapping object from the Registry.
--- @param terminator_consumed boolean  True when the terminator is part of the trigger.
--- @return table  An ExpansionResult.
local function _build_result(mapping, terminator_consumed)
	local bs_count = mapping.trigger_bytes + (terminator_consumed and 1 or 0)
	return {
		replacement        = mapping.plain_repl or mapping.repl,
		backspace_count    = bs_count,
		consume_terminator = terminator_consumed,
		is_final           = mapping.final_result or false,
		group              = mapping.group,
		trigger            = mapping.trigger,
		color              = mapping.color or nil,
	}
end



--- ================================
--- ================================
--- ======= 5/ Port Contract =======
--- ================================
--- ================================

--- =========================
--- ===== 5.1) M.decide =====
--- =========================

--- Decides whether to expand the current buffer.
--- Queries the Registry for candidates whose tail matches tail_char, then
--- iterates in longest-first order (Registry guarantees this), checks that
--- the buffer ends with the trigger, enforces word-boundary rules, and
--- returns the first match.
---
--- @param buffer    string  The full typing buffer.
--- @param tail_char string  The character just typed.
--- @param opts      table|nil  { terminator_consumed: boolean }
--- @return table|nil  An ExpansionResult, or nil when no mapping matches.
function M.decide(buffer, tail_char, opts)
	if not require_state("decide") then return nil end
	if type(buffer) ~= "string" or type(tail_char) ~= "string" then return nil end
	opts = opts or {}
	local terminator_consumed = opts.terminator_consumed == true

	local candidates = _registry.mappings_for_tail(tail_char)
	for _, mapping in ipairs(candidates) do
		-- Check whether the buffer ends with this trigger
		local tlen = mapping.trigger_bytes
		if #buffer >= tlen then
			local suffix = buffer:sub(-tlen)
			if suffix == mapping.trigger then
				-- Enforce word-boundary rule for is_word mappings
				local boundary_ok = (not mapping.is_word) or _word_boundary_ok(buffer, tlen)
				if boundary_ok then
					-- Arm cycling state so cycle_next() can pick up from here
					_cycle_base       = mapping.star_base
					_cycle_candidates = candidates
					_cycle_index      = nil
					for i, c in ipairs(candidates) do
						if c == mapping then _cycle_index = i; break end
					end
					return _build_result(mapping, terminator_consumed)
				end
			end
		end
	end
	return nil
end


--- =============================
--- ===== 5.2) M.cycle_next =====
--- =============================

--- Advances to the next magic-key mapping for the same star_base as the last
--- expansion. Returns nil when no further candidates exist in the bucket.
---
--- @param buffer string  Buffer state at cycle time (used for backspace count).
--- @return table|nil  The next ExpansionResult, or nil.
function M.cycle_next(buffer)
	if not require_state("cycle_next") then return nil end
	if not _cycle_base or not _cycle_candidates or not _cycle_index then
		return nil
	end

	-- Collect all candidates that share the same star_base
	local star_bucket = {}
	for _, c in ipairs(_cycle_candidates) do
		if c.star_base == _cycle_base then
			table.insert(star_bucket, c)
		end
	end

	if #star_bucket < 2 then return nil end

	-- Find the position of the current mapping inside the star bucket
	local current = _cycle_candidates[_cycle_index]
	local pos_in_bucket = nil
	for i, c in ipairs(star_bucket) do
		if c == current then pos_in_bucket = i; break end
	end

	if not pos_in_bucket then return nil end

	-- Advance cyclically
	local next_pos = (pos_in_bucket % #star_bucket) + 1
	local next_mapping = star_bucket[next_pos]

	-- Update cycle index to point at the new mapping in the full candidate list
	for i, c in ipairs(_cycle_candidates) do
		if c == next_mapping then _cycle_index = i; break end
	end

	-- Backspace count covers the previous expansion's replacement plus the trigger
	local prev_repl_len = #(current.plain_repl or current.repl)
	local result = _build_result(next_mapping, false)
	result.backspace_count = prev_repl_len
	return result
end


--- ========================
--- ===== 5.3) M.reset =====
--- ========================

--- Clears all cycling state. Must be called on Escape, focus change, or
--- when the buffer is externally cleared.
--- @return nil
function M.reset()
	_cycle_base       = nil
	_cycle_index      = nil
	_cycle_candidates = nil
end


return M
