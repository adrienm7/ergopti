--- modules/gestures/conflicts.lua

--- ==============================================================================
--- MODULE: Gestures Conflicts
--- DESCRIPTION:
--- Manages macOS system gesture conflicts to prevent double-triggering.
--- Provides instructional alerts to guide the user in disabling native gestures.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local i18n        = require("infra.i18n")
local ShellRunner = require("adapters.shell_runner")
local LOG         = "gestures.conflicts"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- The current-host preferences capture the Trackpad pane's hardware-specific
-- values while the two domains cover the built-in and Bluetooth trackpads
local MACOS_PREFERENCE_COMMANDS = {
	"/usr/bin/defaults read com.apple.AppleMultitouchTrackpad 2>/dev/null",
	"/usr/bin/defaults read com.apple.driver.AppleBluetoothMultitouch.trackpad 2>/dev/null",
	"/usr/bin/defaults -currentHost read -globalDomain 2>/dev/null",
}

local MACOS_PREFERENCE_KEYS = {
	"TrackpadScroll",
	"AppleEnableSwipeNavigateWithScrolls",
	"TrackpadTwoFingerFromRightEdgeSwipeGesture",
	"com.apple.trackpad.twoFingerFromRightEdgeSwipeGesture",
	"TrackpadThreeFingerTapGesture",
	"com.apple.trackpad.threeFingerTapGesture",
	"TrackpadThreeFingerHorizSwipeGesture",
	"com.apple.trackpad.threeFingerHorizSwipeGesture",
	"TrackpadThreeFingerVertSwipeGesture",
	"com.apple.trackpad.threeFingerVertSwipeGesture",
	"TrackpadFourFingerHorizSwipeGesture",
	"com.apple.trackpad.fourFingerHorizSwipeGesture",
	"TrackpadFourFingerVertSwipeGesture",
	"com.apple.trackpad.fourFingerVertSwipeGesture",
}

-- Each group maps a human-readable description to the slots that conflict with
-- a built-in macOS gesture, plus the exact preferences that disable it
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
		preferences  = {
			"TrackpadScroll",
			"AppleEnableSwipeNavigateWithScrolls",
			"TrackpadTwoFingerFromRightEdgeSwipeGesture",
			"com.apple.trackpad.twoFingerFromRightEdgeSwipeGesture",
		},
	},
	{
		key          = "tap_3_conflict",
		slots        = { "tap_3" },
		description  = i18n.get("gestures.conflict_desc_tap_3"),
		hint         = i18n.get("gestures.conflict_hint_tap_3"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
		preferences  = { "TrackpadThreeFingerTapGesture", "com.apple.trackpad.threeFingerTapGesture" },
	},
	{
		key          = "swipe_3_horiz_conflict",
		slots        = { "swipe_3_horiz", "swipe_3_left", "swipe_3_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_horiz"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
		preferences  = { "TrackpadThreeFingerHorizSwipeGesture", "com.apple.trackpad.threeFingerHorizSwipeGesture" },
	},
	{
		key          = "swipe_3_vert_conflict",
		slots        = { "swipe_3_up", "swipe_3_down" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_vert"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
		preferences  = { "TrackpadThreeFingerVertSwipeGesture", "com.apple.trackpad.threeFingerVertSwipeGesture" },
	},
	{
		key          = "swipe_4_horiz_conflict",
		slots        = { "swipe_4_horiz", "swipe_5_horiz", "swipe_4_left", "swipe_4_right", "swipe_5_left", "swipe_5_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_4_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_horiz"),
		settings_url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
		preferences  = { "TrackpadFourFingerHorizSwipeGesture", "com.apple.trackpad.fourFingerHorizSwipeGesture" },
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
		preferences  = { "TrackpadFourFingerVertSwipeGesture", "com.apple.trackpad.fourFingerVertSwipeGesture" },
	},
}

local SLOT_TO_GROUP = {}
for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
	for _, slot in ipairs(grp.slots) do
		SLOT_TO_GROUP[slot] = grp
	end
end





-- =================================
-- =================================
-- ======= 2/ Core Evaluator =======
-- =================================
-- =================================

--- Returns true when an action is meaningful after trimming user input.
--- @param action any The configured action identifier.
--- @return boolean True when the action activates a gesture.
local function action_is_active(action)
	return type(action) == "string" and action ~= "none" and action:match("%S") ~= nil
end

--- Returns true when at least one slot in the group has an active configuration.
--- @param grp table The gesture group.
--- @param ga_table table The active gesture actions map.
--- @return boolean True if active.
local function group_has_active_slot(grp, ga_table)
	for _, slot in ipairs(grp.slots) do
		if action_is_active(ga_table[slot]) then return true end
	end
	return false
end

--- Escapes a preference key for a plain Lua pattern match.
--- @param key string The macOS preference key.
--- @return string The escaped Lua pattern.
local function escape_lua_pattern(key)
	return (key:gsub("([^%w])", "%%%1"))
end

--- Parses a defaults-read value into a numeric on/off state.
--- @param raw string|nil The raw preference value.
--- @return number|nil Zero for disabled, a non-zero number for enabled, or nil.
local function parse_preference_value(raw)
	if type(raw) ~= "string" then return nil end
	local value = raw:match("^%s*(.-)%s*$"):lower()
	if value == "true" or value == "yes" then return 1 end
	if value == "false" or value == "no" then return 0 end
	return tonumber(value)
end

--- Reads the current macOS Trackpad preferences from every relevant source.
--- @return table<string, table<number>> Values grouped by preference key.
local function read_macos_preferences()
	local values = {}
	for _, command in ipairs(MACOS_PREFERENCE_COMMANDS) do
		local output = ShellRunner.exec(command)
		if type(output) == "string" and output ~= "" then
			for _, key in ipairs(MACOS_PREFERENCE_KEYS) do
				local escaped = escape_lua_pattern(key)
				local raw = output:match('"' .. escaped .. '"%s*=%s*([^;\n]+)')
					or output:match(escaped .. "%s*=%s*([^;\n]+)")
				local value = parse_preference_value(raw)
				if value ~= nil then
					values[key] = values[key] or {}
					table.insert(values[key], value)
				end
			end
		end
	end
	return values
end

--- Returns true only when macOS explicitly reports every relevant setting off.
--- @param grp table The gesture group.
--- @param preferences table<string, table<number>> Current macOS values.
--- @return boolean True when the matching native gesture is disabled.
local function macos_gesture_is_disabled(grp, preferences)
	local found = false
	for _, key in ipairs(grp.preferences) do
		for _, value in ipairs(preferences[key] or {}) do
			found = true
			if value ~= 0 then return false end
		end
	end
	return found
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Generates a warning structure if a new action triggers a system conflict.
--- @param slot string The gesture slot name.
--- @param new_action string The newly assigned action.
--- @return table|nil Warning data or nil if no conflict.
function M.on_action_changed(slot, new_action)
	if not action_is_active(new_action) then return nil end
	local grp = SLOT_TO_GROUP[slot]
	if not grp then return nil end
	if macos_gesture_is_disabled(grp, read_macos_preferences()) then
		Logger.debug(LOG, "Native macOS gesture '%s' is disabled — conflict warning suppressed.", grp.key)
		return nil
	end
	
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
	if type(active_actions) ~= "table" then
		Logger.error(LOG, "apply_all_overrides(): active_actions must be a table.")
		return
	end
	Logger.debug(LOG, "Evaluating all overrides for conflicts…")
	local preferences = read_macos_preferences()
	for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
		if group_has_active_slot(grp, active_actions) then
			if not macos_gesture_is_disabled(grp, preferences) then
				Logger.warn(LOG, string.format("Active conflict: \"%s\" — please disable it in System Settings.", grp.description))
			end
		end
	end
	Logger.info(LOG, "Overrides conflict evaluation completed.")
end

--- No-op function (we never modify system prefs automatically).
function M.restore_all_overrides()
end

return M
