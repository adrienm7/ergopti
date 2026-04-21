--- modules/keymap/state.lua

--- ==============================================================================
--- MODULE: Keymap CoreState factory
--- DESCRIPTION:
--- Owns the shared-state table passed by reference to every keymap submodule
--- (Registry, Expander, LLMBridge, utils). Previously defined inline in
--- keymap/init.lua; extracting it here makes the set of invariants that the
--- submodules rely on explicit and easier to reason about in isolation.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth for initial values: a factory function seeds
---    every field from the canonical DEFAULT_STATE / DELAYS_DEFAULT tables
---    supplied by keymap/init.lua. Submodules never re-declare defaults.
--- 2. Closure-bound methods: suppress_rescan and suppress_rescan_keep_buffer
---    are bound to the new state table at creation time so callers never have
---    to thread the state handle through.
--- 3. Declared Invariants: comments on the index fields document which pairs
---    must stay consistent (e.g. mappings / mappings_by_tail_char) — the
---    Registry is responsible for maintaining these after any structural
---    change, but the invariant lives here with the state definition.
--- ==============================================================================

local hs = hs
local M  = {}




-- =============================================
-- =============================================
-- ======= 1/ Default Initialisation Seeds =====
-- =============================================
-- =============================================

-- Default seconds the rescan window uses when callers do not pass an explicit
-- duration to suppress_rescan(). Picked empirically to bridge the gap between
-- an expansion firing and the next user keystroke without swallowing more
-- than one human-speed key.
local DEFAULT_SUPPRESS_SEC      = 0.5
local DEFAULT_SUPPRESS_KEEP_SEC = 0.3




-- =====================================
-- =====================================
-- ======= 2/ State Factory ============
-- =====================================
-- =====================================

--- Builds a fresh CoreState table seeded from the canonical defaults.
---
--- The returned table carries:
---   - the rolling keystroke buffer and its synthetic-event bookkeeping,
---   - the mapping database (flat list + O(1) lookup + tail-char buckets),
---   - the terminator/delay configuration pulled from the supplied defaults,
---   - bound closures (suppress_rescan / suppress_rescan_keep_buffer) that
---     mutate the same table rather than any module-level state.
---
--- Invariants the Registry must maintain after any structural change:
---   * mappings_lookup[trigger .. "\0" .. is_word .. "\0" .. auto] points to
---     the same entry that appears in mappings (flat list).
---   * For every entry e in mappings, e.tail_char indexes it inside
---     mappings_by_tail_char; if e.has_magic then e.star_base_tail_char
---     indexes it inside mappings_by_star_tail_char.
---   * mappings stays sorted by (tlen desc, is_word first, group_order asc,
---     seq asc) at all times.
---
--- @param defaults table The DEFAULT_STATE table from keymap/init.lua.
--- @param delays_default table The DELAYS_DEFAULT table from keymap/init.lua.
--- @return table The freshly-seeded CoreState.
function M.new(defaults, delays_default)
	if type(defaults) ~= "table" then
		error("state.new(): defaults must be a table (got " .. type(defaults) .. ").")
	end
	if type(delays_default) ~= "table" then
		error("state.new(): delays_default must be a table (got " .. type(delays_default) .. ").")
	end

	local s = {
		buffer                     = "",
		magic_key                  = defaults.trigger_char,
		-- Flat list of mapping entries, sorted longest-first. See the
		-- invariants comment above for how the adjacent indexes must stay
		-- consistent with this list.
		mappings                   = {},
		mappings_lookup            = {},
		mappings_by_tail_char      = {},
		mappings_by_star_tail_char = {},
		groups                     = {},
		seq_counter                = 0,
		-- Monotonic counter assigned on first registration of a group name;
		-- stable across disable/enable cycles so the sort tiebreaker
		-- (group_order asc) cannot flip priority of same-length triggers.
		group_order_counter        = 0,
		interceptors               = {},
		preview_providers          = {},
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		shift_side                 = nil,
		processing_paused          = false,
		last_key_time              = 0,
		last_key_was_complex       = false,
		no_rescan_until            = 0,
		WORD_TIMEOUT_SEC           = 5.0,
		BASE_DELAY_SEC             = defaults.expansion_delay,
		DELAYS                     = {},
		DELAYS_DEFAULT             = delays_default,
		current_group              = nil,
		group_post_load_hooks      = {},
		ignored_window_titles      = {},
		ignored_window_patterns    = {},
	}

	-- Closure-bound so callers hold a single s reference and never have to
	-- thread the state handle through. suppress_rescan always wipes the
	-- buffer (used after an expansion) while suppress_rescan_keep_buffer
	-- leaves it intact (used for sequential hotstring chains).
	s.suppress_rescan = function(duration)
		s.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or DEFAULT_SUPPRESS_SEC)
		s.buffer = ""
	end

	s.suppress_rescan_keep_buffer = function(duration)
		s.no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or DEFAULT_SUPPRESS_KEEP_SEC)
	end

	-- Seed the initial per-group delays from defaults and compute the
	-- word-timeout. A delay of 0 for any group means "always-active
	-- trigger" — in that case the word-timeout must be infinite so the
	-- buffer is never auto-wiped behind the user's back.
	local has_infinite = false
	local max_delay    = 0
	for k, v in pairs(delays_default) do
		s.DELAYS[k] = v
		if v == 0 then has_infinite = true end
		if v > max_delay then max_delay = v end
	end
	s.WORD_TIMEOUT_SEC = has_infinite and 0 or (max_delay + 0.5)

	return s
end

return M
