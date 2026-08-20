--- _shared/lua/tap_hold/kanata_generator.lua
---
--- Pure-Lua generator: produces the ``(defalias)`` block of ``kanata.kbd``
--- containing tap-hold-press and one-shot directives from the shared
--- ``_shared/tap_hold/defaults.toml`` timeouts.
---
--- This module is driver-agnostic — it takes parsed data as input and returns
--- a string. It does NOT read files, parse TOML, or call any driver functions.
---
--- Usage:
---   local gen = require("tap_hold.kanata_generator")
---   local defalias_block = gen.generate(keys_config, {
---       one_shot_shift_timeout_ms = 2000,
---   })
---
--- Input ``keys_config`` is a table keyed by defaults.toml key id
--- (e.g. "caps_lock", "left_shift") with at least:
---   { time_activation_seconds = number, tap_action = string, hold_modifier = string|nil, hold_layer = string|nil }
---
--- The generated block REPLACES the last ``(defalias)`` block of
--- ``linux/platform/remap/data/kanata.kbd`` wholesale, so it must be
--- self-sufficient in two ways:
---
--- 1. Multi-key tap/hold expressions the shared data model cannot encode (such
---    as ``alt_gr``'s modifier-release sequence) come from EXPRESSION_OVERRIDES
---    below. They used to be left to "hand-post-processing by the caller",
---    which no caller ever did — the hand-tuned expression was simply lost.
--- 2. Aliases the emitted directives REFERENCE (``@copy``, ``@paste``) must be
---    defined somewhere the generator does not overwrite. They live in the
---    hand-maintained composites block that precedes the generated one, because
---    kanata resolves every ``@name`` at load time: a single dangling reference
---    makes the WHOLE configuration unloadable, not just that one key.

local M = {}

-- ============================================================================
-- Mapping: defaults.toml key id → kanata alias name + action strings.
-- Each entry maps the shared defaults.toml semantic actions to kanata-native
-- key names and directive bodies. These mappings are OS-specific because
-- kanata key names and layer names differ from the cross-driver abstractions.
-- ============================================================================

--- Maps defaults.toml tap_action → kanata action body string.
--- Actions that don't appear here are passed through as kanata key names
--- (e.g. "enter", "tab", "backspace").
local TAP_ACTION_MAP = {
	copy              = "@copy",
	paste             = "@paste",
	backspace         = "bspc",
	enter             = "enter",
	tab               = "tab",
	one_shot_shift    = nil,  -- handled specially: emits (one-shot ...) instead of tap-hold-press
	alt_tab_monitor   = "(multi lalt tab)",
}

--- Maps defaults.toml hold_modifier → kanata modifier name.
local HOLD_MODIFIER_MAP = {
	ctrl   = "lctl",
	shift  = "lsft",
	alt    = "lalt",
	alt_gr = "ralt",
}

--- Maps defaults.toml hold_layer → kanata layer-toggle expression.
local HOLD_LAYER_MAP = {
	nav = "(layer-toggle navigation)",
}

--- Maps defaults.toml key id → kanata alias name.
local KEY_ALIAS_MAP = {
	caps_lock  = "cap",
	left_shift = "lsft",
	left_ctrl  = "lctl",
	left_alt   = "lalt",
	alt_gr     = "ralt",
	tab        = "alttab",
	right_ctrl = "ossft",   -- right_ctrl in defaults.toml maps to one_shot_shift
}

--- Tap/hold expressions the shared data model cannot encode, keyed by
--- defaults.toml key id.
---
--- defaults.toml has no vocabulary for a modifier-release sequence, so without
--- this table alt_gr was generated as `(tap-hold-press 200 200 tab ralt)` — the
--- release-key steps of the hand-tuned config were silently dropped and
--- window-switching left ctrl and alt stuck down. The timeout still comes from
--- the TOML; only the expression is overridden here.
local EXPRESSION_OVERRIDES = {
	alt_gr = {
		tap  = "(multi (release-key lctl) (release-key lalt) tab)",
		hold = "(multi ralt (release-key lctl))",
	},
}

--- Default one-shot shift timeout in ms (kanata uses integer ms).
--- Fallback only; callers SHOULD pass the canonical value from
--- _shared/modules/timings/constants.toml [tap_hold] one_shot_shift_timeout_ms.
--- Remove when all callers pass the value explicitly — this literal is a
--- stale-trap: if the TOML changes, the generator silently diverges.
local DEFAULT_ONE_SHOT_MS = 2000

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Rounds a number to the nearest integer.
--- @param n number
--- @return integer
local function round(n)
	return math.floor(n + 0.5)
end

--- Converts time_activation_seconds to milliseconds (integer).
--- @param secs number|nil
--- @return integer ms
local function to_ms(secs)
	local s = tonumber(secs)
	if not s or s <= 0 then return 200 end  -- fallback: 200 ms
	return round(s * 1000)
end

--- Resolves the tap action body for kanata.
--- @param tap_action string The defaults.toml tap_action value.
--- @return string|nil kanata action body, or nil if none.
local function resolve_tap(tap_action)
	if not tap_action or tap_action == "none" then return nil end
	return TAP_ACTION_MAP[tap_action] or tap_action
end

--- Resolves the hold action body for kanata.
--- @param key_config table {hold_modifier, hold_layer}
--- @return string|nil kanata hold body, or nil if none.
local function resolve_hold(key_config)
	local mod = key_config.hold_modifier
	if mod and mod ~= "none" then
		local name = HOLD_MODIFIER_MAP[mod]
		if name then return name end
	end
	local layer = key_config.hold_layer
	if layer and layer ~= "none" then
		local expr = HOLD_LAYER_MAP[layer]
		if expr then return expr end
	end
	return nil
end

--- Returns true when the key's tap action is one_shot_shift.
--- @param key_config table
--- @return boolean
local function is_one_shot_shift(key_config)
	return key_config.tap_action == "one_shot_shift"
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Generates the ``(defalias)`` block for tap-hold-press and one-shot
--- directives.
---
--- @param keys_config table  Map of key_id → {time_activation_seconds, tap_action, hold_modifier, hold_layer}
--- @param opts      table|nil  { one_shot_shift_timeout_ms = number }
--- @return string  The complete (defalias ...) block as a string.
function M.generate(keys_config, opts)
	opts = opts or {}
	local one_shot_ms = tonumber(opts.one_shot_shift_timeout_ms)
		or DEFAULT_ONE_SHOT_MS

	local lines = { "(defalias" }

	-- Iterate in a stable order so the generated output is deterministic.
	-- Use the KEY_ALIAS_MAP keys as the iteration order (the same order
	-- the hand-written kanata.kbd uses).
	for _, key_id in ipairs({
		"tab", "caps_lock", "left_shift", "left_ctrl", "left_alt",
		"alt_gr", "right_ctrl",
	}) do
		local kc = keys_config[key_id]
		if not kc then goto continue end

		local alias = KEY_ALIAS_MAP[key_id]
		if not alias then goto continue end

		if is_one_shot_shift(kc) then
			-- One-shot shift: emits (one-shot <ms> lsft) instead of tap-hold-press
			lines[#lines + 1] = string.format(
				"    %-10s (one-shot %d lsft)",
				alias, one_shot_ms
			)
		else
			local ms = to_ms(kc.time_activation_seconds)
			-- The timeout stays TOML-driven; only expressions the shared model
			-- cannot represent are taken from the override table.
			local override = EXPRESSION_OVERRIDES[key_id]
			local tap  = (override and override.tap)  or resolve_tap(kc.tap_action)
			local hold = (override and override.hold) or resolve_hold(kc)

			if tap and hold then
				lines[#lines + 1] = string.format(
					"    %-10s (tap-hold-press %d %d %s %s)",
					alias, ms, ms, tap, hold
				)
			elseif hold then
				-- Hold only, no tap action: use passthrough tap
				lines[#lines + 1] = string.format(
					"    %-10s (tap-hold-press %d %d _ %s)",
					alias, ms, ms, hold
				)
			elseif tap then
				-- Tap only, no hold: use passthrough hold
				lines[#lines + 1] = string.format(
					"    %-10s (tap-hold-press %d %d %s _)",
					alias, ms, ms, tap
				)
			end
			-- If neither tap nor hold, skip this key (no directive needed)
		end

		::continue::
	end

	lines[#lines + 1] = ")"
	return table.concat(lines, "\n") .. "\n"
end

return M
