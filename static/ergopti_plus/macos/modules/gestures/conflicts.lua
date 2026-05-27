--- modules/gestures/conflicts.lua

--- ==============================================================================
--- MODULE: Gestures Conflicts
--- DESCRIPTION:
--- Manages macOS system gesture conflicts to prevent double-triggering.
--- Provides instructional alerts to guide the user in disabling native gestures.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local LOG    = "gestures.conflicts"





-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

-- Each group maps a human-readable description to the slots that conflict with
-- a built-in macOS gesture, plus the exact path to toggle it in System Settings
local MACOS_GESTURE_GROUPS = {
	{
		key          = "swipe_2_conflict",
		slots        = { 
			"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down",
			"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down"
		},
		description  = i18n.get("gestures.conflict_desc_swipe_2"),
		hint         = i18n.get("gestures.conflict_hint_swipe_2"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
	{
		key          = "tap_3_conflict",
		slots        = { "tap_3" },
		description  = i18n.get("gestures.conflict_desc_tap_3"),
		hint         = i18n.get("gestures.conflict_hint_tap_3"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
	{
		key          = "swipe_3_horiz_conflict",
		slots        = { "swipe_3_horiz", "swipe_3_left", "swipe_3_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_horiz"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
	{
		key          = "swipe_3_vert_conflict",
		slots        = { "swipe_3_up", "swipe_3_down" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_vert"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
	{
		key          = "swipe_4_horiz_conflict",
		slots        = { "swipe_4_horiz", "swipe_5_horiz", "swipe_4_left", "swipe_4_right", "swipe_5_left", "swipe_5_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_4_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_horiz"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
	{
		key          = "swipe_4_vert_conflict",
		slots        = { 
			"swipe_4_up", "swipe_4_down", "swipe_5_up", "swipe_5_down",
			"swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down",
			"swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down"
		},
		description  = i18n.get("gestures.conflict_desc_swipe_4_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_vert"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
	},
}

local SLOT_TO_GROUP = {}
for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
	for _, slot in ipairs(grp.slots) do
		SLOT_TO_GROUP[slot] = grp
	end
end





-- =================================
--- =================================
-- ======= 2/ Core Evaluator =======
--- =================================
-- =================================

--- Returns true when at least one slot in the group has an active configuration.
--- @param grp table The gesture group.
--- @param ga_table table The active gesture actions map.
--- @return boolean True if active.
local function group_has_active_slot(grp, ga_table)
	for _, slot in ipairs(grp.slots) do
		if (ga_table[slot] or "none") ~= "none" then return true end
	end
	return false
end





-- =============================
--- =============================
-- ======= 3/ Public API =======
--- =============================
-- =============================

--- Generates a warning structure if a new action triggers a system conflict.
--- @param slot string The gesture slot name.
--- @param new_action string The newly assigned action.
--- @return table|nil Warning data or nil if no conflict.
function M.on_action_changed(slot, new_action)
	if new_action == "none" then return nil end
	local grp = SLOT_TO_GROUP[slot]
	if not grp then return nil end
	
	Logger.warn(LOG, string.format("Potential macOS system conflict detected for slot: %s.", slot))
	
	-- A line of dashes forces the blockAlert dialog to be wide enough in UI
	local sep = string.rep("─", 26)
	return {
		msg = string.format(
			"%s\n"
			.. i18n.get("gestures.conflict_dialog_line1") .. "\n"
			.. "« %s »\n\n"
			.. i18n.get("gestures.conflict_dialog_line2") .. "\n"
			.. i18n.get("gestures.conflict_dialog_line3") .. "\n\n"
			.. i18n.get("gestures.conflict_dialog_line4") .. "\n"
			.. "%s\n%s",
			sep, grp.description, grp.hint, sep),
		url = grp.settings_url,
	}
end

--- Logs active conflicts at startup (no automatic preference changes).
--- @param active_actions table The currently configured user actions.
function M.apply_all_overrides(active_actions)
	Logger.debug(LOG, "Evaluating all overrides for conflicts…")
	for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
		if group_has_active_slot(grp, active_actions) then
			Logger.warn(LOG, string.format("Active conflict: \"%s\" — please disable it in System Settings.", grp.description))
		end
	end
	Logger.info(LOG, "Overrides conflict evaluation completed.")
end

--- No-op function (we never modify system prefs automatically).
function M.restore_all_overrides()
end

return M
