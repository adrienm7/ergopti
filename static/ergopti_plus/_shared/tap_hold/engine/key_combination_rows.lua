--- _shared/tap_hold/engine/key_combination_rows.lua

--- ==============================================================================
--- MODULE: Key Combination Pair Rows
--- DESCRIPTION:
--- The Windows layout of the key-combination pair rows, which every OS follows
--- (maintainer decision KCD-8 of 2026-11-21): one submenu per first key, one row
--- per pair named « First + Second » and its summary, then in the pair's own
--- menu the tap, hold and chord slots in that order. Windows spells the same
--- rule in KeyCombinationPairSummary (windows/infra/key_combinations.ahk); all
--- of them replay _shared/tests/corpus/tap_hold/key_combination_pair_rows.json.
--- ==============================================================================

local LabelValue = require("core.i18n.engine.label_value")

local M = {}

--- The slots of a pair's own menu, in the order they are drawn.
M.SLOT_ORDER = { "tap", "hold", "combo" }
--- The word an empty tap or chord slot shows, as the action picker names it.
M.EMPTY_ACTION_KEY = "dialog.action_picker.disabled"
--- The word an empty hold slot shows, as the tap-hold menus name it.
M.EMPTY_HOLD_KEY = "tap_hold.hold.none"

--- A pair's summary: its tap, its hold beside it when it has one, the hold
--- alone when the tap is empty, the empty word when neither is set. A chord
--- shows in the pair's own menu and ticks the row, never in this text.
--- @param get function The i18n lookup, key to text.
--- @param tap_label string|nil The tap's label, nil when empty.
--- @param hold_label string|nil The hold's label, nil when empty.
--- @return string
function M.summary(get, tap_label, hold_label)
	assert(type(get) == "function", "i18n lookup required")
	if hold_label ~= nil then
		return tap_label ~= nil and (tap_label .. " / " .. hold_label) or hold_label
	end
	return tap_label or get(M.EMPTY_ACTION_KEY)
end

--- A pair's row label, « First + Second » joined to its summary.
--- @param get function The i18n lookup, key to text.
--- @param first_label string The first key's label.
--- @param second_label string The second key's label.
--- @param tap_label string|nil The tap's label, nil when empty.
--- @param hold_label string|nil The hold's label, nil when empty.
--- @return string
function M.pair_label(get, first_label, second_label, tap_label, hold_label)
	return LabelValue.compose(get, first_label .. " + " .. second_label, M.summary(get, tap_label, hold_label))
end

return M
