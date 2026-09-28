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
	{ "read", "com.apple.AppleMultitouchTrackpad" },
	{ "read", "com.apple.driver.AppleBluetoothMultitouch.trackpad" },
	{ "-currentHost", "read", "-globalDomain" },
}

local cached_preferences = {}
local pending_probe = nil
local boot_notified = false
local SETTINGS_URL = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
local THREE_FINGER_DRAG_KEYS = { "TrackpadThreeFingerDrag", "com.apple.trackpad.threeFingerDragGesture" }

local MACOS_PREFERENCE_KEYS = {
	"TrackpadRightClick",
	"TrackpadThreeFingerDrag",
	"com.apple.trackpad.threeFingerDragGesture",
	"TrackpadPinch",
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
		key = "tap_2_conflict", slots = { "tap_2" },
		description = i18n.get("gesture.slots.tap_2"),
		hint = i18n.get("menu.gestures.open_settings"),
		settings_url = SETTINGS_URL,
		preferences = { "TrackpadRightClick" },
	},
	{
		key          = "swipe_2_conflict",
		slots        = { 
			"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down",
			"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down"
		},
		description  = i18n.get("gestures.conflict_desc_swipe_2"),
		hint         = i18n.get("gestures.conflict_hint_swipe_2"),
		settings_url = SETTINGS_URL,
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
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadThreeFingerTapGesture", "com.apple.trackpad.threeFingerTapGesture" },
	},
	{
		key          = "swipe_3_horiz_conflict",
		slots        = { "swipe_3_horiz", "swipe_3_left", "swipe_3_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_horiz"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadThreeFingerHorizSwipeGesture", "com.apple.trackpad.threeFingerHorizSwipeGesture" },
		drag_preferences = THREE_FINGER_DRAG_KEYS,
	},
	{
		key          = "swipe_3_vert_conflict",
		slots        = { "swipe_3_up", "swipe_3_down", "swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_vert"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadThreeFingerVertSwipeGesture", "com.apple.trackpad.threeFingerVertSwipeGesture" },
		drag_preferences = THREE_FINGER_DRAG_KEYS,
	},
	{
		key          = "swipe_4_horiz_conflict",
		slots        = { "swipe_4_horiz", "swipe_5_horiz", "swipe_4_left", "swipe_4_right", "swipe_5_left", "swipe_5_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_4_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_horiz"),
		settings_url = SETTINGS_URL,
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
		settings_url = SETTINGS_URL,
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

--- Accumulates one completed defaults output without publishing a partial read.
--- @param values table Candidate snapshot.
--- @param output string Native output.
local function parse_output(values, output)
	for _, key in ipairs(MACOS_PREFERENCE_KEYS) do
		local escaped = escape_lua_pattern(key)
		local raw = output:match('"' .. escaped .. '"%s*=%s*([^;\n]+)')
			or output:match("%f[%w]" .. escaped .. "%s*=%s*([^;\n]+)")
		local value = parse_preference_value(raw)
		if value ~= nil then
			values[key] = values[key] or {}
			table.insert(values[key], value)
		end
	end
end

--- Refreshes the cache asynchronously; simultaneous requests share one probe.
--- @param on_done function|nil Called after the complete snapshot is published.
--- @return boolean accepted
function M.refresh(on_done)
	if pending_probe then
		if on_done then pending_probe.waiters[#pending_probe.waiters + 1] = on_done end
		return true
	end
	local probe = { values = {}, remaining = #MACOS_PREFERENCE_COMMANDS, waiters = {}, handles = {} }
	if on_done then probe.waiters[1] = on_done end
	pending_probe = probe
	Logger.start(LOG, "Reading system gesture settings asynchronously…")
	for _, args in ipairs(MACOS_PREFERENCE_COMMANDS) do
		local settled = false
		local function complete(code, output)
			if settled or pending_probe ~= probe then return end
			settled = true
			if code == 0 and type(output) == "string" then parse_output(probe.values, output) end
			probe.remaining = probe.remaining - 1
			if probe.remaining ~= 0 then return end
			cached_preferences = probe.values
			pending_probe = nil
			if next(cached_preferences) == nil then
				Logger.warn(LOG, "System gesture preferences are unavailable; conflicts remain unverified.")
			else
				Logger.success(LOG, "System gesture settings cached.")
			end
			for _, callback in ipairs(probe.waiters) do
				local ok, err = xpcall(callback, debug.traceback)
				if not ok then Logger.error(LOG, "Gesture status callback failed: %s.", tostring(err)) end
			end
		end
		local ok, handle = pcall(ShellRunner.spawn, "/usr/bin/defaults", args, complete)
		if ok and type(handle) == "table" then probe.handles[#probe.handles + 1] = handle end
		if not ok or type(handle) ~= "table" or handle.isSettled() then complete(-1, "") end
	end
	return true
end

--- Returns true when at least one native alias is known and every observed value is off.
--- @param keys table Native aliases for one policy.
--- @param preferences table<string, table<number>> Current macOS values.
--- @return boolean disabled
local function preference_is_disabled(keys, preferences)
	local found = false
	for _, key in ipairs(keys) do
		for _, value in ipairs(preferences[key] or {}) do
			found = true
			if value ~= 0 then return false end
		end
	end
	return found
end

--- Native dragging and swiping are independent policies, not aliases of each other.
--- @param grp table Gesture conflict group.
--- @param preferences table Cached native values.
--- @return boolean disabled
local function macos_gesture_is_disabled(grp, preferences)
	return preference_is_disabled(grp.preferences, preferences)
		and (not grp.drag_preferences or preference_is_disabled(grp.drag_preferences, preferences))
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
	if macos_gesture_is_disabled(grp, cached_preferences) then
		Logger.debug(LOG, "Native macOS gesture '%s' is disabled — conflict warning suppressed.", grp.key)
		return nil
	end
	
	Logger.warn(LOG, string.format("Potential macOS system conflict detected for slot: %s.", slot))
	
	-- A line of dashes forces the blockAlert dialog to be wide enough in UI
	local sep = string.rep("─", 26)
	return {
		key = grp.key,
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
--- @param is_enabled function|nil Reads the committed posture after asynchronous probing.
function M.apply_all_overrides(active_actions, is_enabled)
	if type(active_actions) ~= "table" then
		Logger.error(LOG, "apply_all_overrides(): active_actions must be a table.")
		return
	end
	return M.refresh(function()
		if boot_notified or not is_enabled or is_enabled() ~= true then return end
		boot_notified = true
		for _, warning in ipairs(M.active_conflicts(active_actions)) do
			require("ui.gesture_conflict_notice").show(warning)
		end
	end)
end

--- Returns cached conflicts for active bindings, once per system group.
--- @param actions table Gesture assignments.
--- @return table warnings
function M.active_conflicts(actions)
	local warnings = {}
	for _, group in ipairs(MACOS_GESTURE_GROUPS) do
		if group_has_active_slot(group, actions) then
			for _, slot in ipairs(group.slots) do
				if action_is_active(actions[slot]) then
					local warning = M.on_action_changed(slot, actions[slot])
					if warning then warning.label = group.description; warnings[#warnings + 1] = warning end
					break
				end
			end
		end
	end
	return warnings
end

--- Reports native pinch configuration without inventing an Ergopti pinch slot.
--- @return boolean|nil enabled Nil means the native setting was not readable.
function M.native_pinch_enabled()
	local values = cached_preferences.TrackpadPinch
	if not values or #values == 0 then return nil end
	for _, value in ipairs(values) do if value ~= 0 then return true end end
	return false
end

--- Opens Trackpad Settings and refreshes the snapshot after the next explicit request.
--- @return boolean started
function M.open_settings()
	return ShellRunner.open(SETTINGS_URL)
end

--- Cancels owned probes during shutdown; system preferences are never modified.
function M.restore_all_overrides()
	local probe = pending_probe
	pending_probe = nil
	if probe then
		Logger.warn(LOG, "System gesture settings read cancelled during shutdown.")
		for _, handle in ipairs(probe.handles) do
			if not handle.isSettled() then handle.terminate() end
		end
	end
end

return M
