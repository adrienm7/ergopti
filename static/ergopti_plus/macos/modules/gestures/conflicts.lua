--- modules/gestures/conflicts.lua

--- ==============================================================================
--- MODULE: Gestures Conflicts
--- DESCRIPTION:
--- Manages macOS system gesture conflicts to prevent double-triggering.
--- Provides instructional alerts to guide the user in disabling native gestures.
---
--- FEATURES & RATIONALE:
--- 1. Never a double action (maintainer, 2026-11-03): while a three-or-more
---    finger macOS gesture is on, the Ergopti slots it covers are "taken"
---    (slot_system_state): the menu greys them and the engine does not fire
---    them. The preferences are only read, never written.
--- 2. Two-finger touches (scroll, secondary click) never block a slot: they are
---    the pointer itself, and the engine already leaves those axes to macOS.
--- 3. The snapshot is re-read by a cheap timer (recheck), off the touch path, so
---    turning a macOS gesture back on greys and suspends its slot, and turning it
---    off brings the slot back, without a reload.
--- ==============================================================================

local M = {}

local Logger      = require("core.logger.engine.logger")
local i18n        = require("core.i18n.engine.i18n")
local ShellRunner = require("adapters.shell_runner")
local Timings     = require("infra.timings")
local TextUtils = require("core.text.engine.utils_core")
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
	-- The Dock owns the Mission Control and App Exposé switches of the
	-- vertical swipes (showMissionControlGestureEnabled, showAppExposeGestureEnabled).
	{ "read", "com.apple.dock" },
}

local cached_preferences = {}
-- False until one complete read is published: before it nothing is known, so
-- no slot is reported taken (the boot read follows within a second).
local snapshot_ready = false
local snapshot_incomplete = false
local snapshot_all_absent = false
local pending_probe = nil
local probe_cleanup_debt = {}
local recheck_pending = false
-- The recheck timer and whoever wants to hear that a slot changed state.
local watch_handle = nil
local state_listener = nil
local boot_notified = false
-- Last logged posture per system group ("conflict" or "disabled"). Every menu
-- rebuild asks for the active conflicts, so only a change is worth a line.
local logged_posture = {}
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
	"showMissionControlGestureEnabled",
	"showAppExposeGestureEnabled",
}

-- Each group maps a human-readable description to the slots that conflict with
-- a built-in macOS gesture, plus the exact preferences that disable it.
-- `blocks` marks the groups whose slots are taken while the macOS gesture is
-- on; `absent_on` is what an unwritten preference means, the macOS default
-- (three-finger swipes are off in a default install, four-finger ones on);
-- `dock` is the Dock switch the vertical swipes also need, with its default.
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
		blocks       = true, absent_on = true,
	},
	{
		key          = "swipe_3_horiz_conflict",
		slots        = { "swipe_3_horiz", "swipe_3_left", "swipe_3_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_horiz"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadThreeFingerHorizSwipeGesture", "com.apple.trackpad.threeFingerHorizSwipeGesture" },
		drag_preferences = THREE_FINGER_DRAG_KEYS,
		blocks       = true, absent_on = false,
	},
	{
		key          = "swipe_3_vert_conflict",
		slots        = { "swipe_3_up", "swipe_3_down", "swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down" },
		description  = i18n.get("gestures.conflict_desc_swipe_3_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_3_vert"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadThreeFingerVertSwipeGesture", "com.apple.trackpad.threeFingerVertSwipeGesture" },
		drag_preferences = THREE_FINGER_DRAG_KEYS,
		blocks       = true, absent_on = false,
	},
	{
		key          = "swipe_4_horiz_conflict",
		slots        = { "swipe_4_horiz", "swipe_5_horiz", "swipe_4_left", "swipe_4_right", "swipe_5_left", "swipe_5_right" },
		description  = i18n.get("gestures.conflict_desc_swipe_4_horiz"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_horiz"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadFourFingerHorizSwipeGesture", "com.apple.trackpad.fourFingerHorizSwipeGesture" },
		blocks       = true, absent_on = true,
	},
	-- The vertical swipes are two macOS gestures: up is Mission Control (on by
	-- default), down is App Exposé (off by default), each with its Dock switch.
	{
		key          = "swipe_4_up_conflict",
		slots        = {
			"swipe_4_up", "swipe_5_up",
			"swipe_4_left_up", "swipe_4_right_up", "swipe_5_left_up", "swipe_5_right_up",
		},
		description  = i18n.get("gestures.conflict_desc_swipe_4_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_vert"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadFourFingerVertSwipeGesture", "com.apple.trackpad.fourFingerVertSwipeGesture" },
		dock         = { key = "showMissionControlGestureEnabled", absent_on = true },
		blocks       = true, absent_on = true,
	},
	{
		key          = "swipe_4_down_conflict",
		slots        = {
			"swipe_4_down", "swipe_5_down",
			"swipe_4_left_down", "swipe_4_right_down", "swipe_5_left_down", "swipe_5_right_down",
		},
		description  = i18n.get("gestures.conflict_desc_swipe_4_vert"),
		hint         = i18n.get("gestures.conflict_hint_swipe_4_vert"),
		settings_url = SETTINGS_URL,
		preferences  = { "TrackpadFourFingerVertSwipeGesture", "com.apple.trackpad.fourFingerVertSwipeGesture" },
		dock         = { key = "showAppExposeGestureEnabled", absent_on = false },
		blocks       = true, absent_on = true,
	},
}

local SLOT_TO_GROUP = {}
local KEY_TO_GROUP = {}
for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
	KEY_TO_GROUP[grp.key] = grp
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
	local value = TextUtils.trim(raw):lower()
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

--- Retires one exact process, retaining it until its native exit is observed.
local function retire_probe_handle(handle)
	local ok, settled = pcall(handle.isSettled)
	if ok and settled == true then probe_cleanup_debt[handle] = nil; return true end
	local debt = probe_cleanup_debt[handle] or { observing = false }
	probe_cleanup_debt[handle] = debt
	pcall(handle.terminate)
	ok, settled = pcall(handle.isSettled)
	if ok and settled == true then probe_cleanup_debt[handle] = nil; return true end
	if not debt.observing and type(handle.onSettled) == "function" then
		debt.observing = true
		local registered, accepted = pcall(handle.onSettled, function()
			if probe_cleanup_debt[handle] == debt then probe_cleanup_debt[handle] = nil end
		end)
		if not registered or accepted ~= true then debt.observing = false end
	end
	return false
end

local function retry_probe_cleanup()
	local snapshot = {}
	for handle in pairs(probe_cleanup_debt) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if not retire_probe_handle(handle) then settled = false end
	end
	return settled
end

--- Refreshes the cache asynchronously; simultaneous requests share one probe.
--- @param on_done function|nil Called after the complete snapshot is published.
--- @return boolean accepted
function M.refresh(on_done)
	if pending_probe then
		if on_done then pending_probe.waiters[#pending_probe.waiters + 1] = on_done end
		return true
	end
	if not retry_probe_cleanup() then
		Logger.error(LOG, "Previous system gesture preference processes are still retiring.")
		return false
	end
	local probe = { values = {}, remaining = #MACOS_PREFERENCE_COMMANDS, waiters = {}, handles = {},
		incomplete = false, absent = 0 }
	if on_done then probe.waiters[1] = on_done end
	pending_probe = probe
	Logger.start(LOG, "Reading system gesture settings asynchronously…")
	for _, args in ipairs(MACOS_PREFERENCE_COMMANDS) do
		if pending_probe ~= probe then break end
		local settled = false
		local start_refused = false
		local function complete(code, output, stderr)
			if settled or pending_probe ~= probe then return end
			settled = true
			if start_refused then code, output = -1, "" end
			if code == 0 and type(output) == "string" then
				parse_output(probe.values, output)
			else
				-- A domain the user never configured is a normal defaults result.
				-- Only that exact diagnostic proves absence; permission, process,
				-- and localized or otherwise unfamiliar failures remain unverified.
				local domain = args[#args]
				local expected = "Domain " .. domain .. " does not exist"
				local absent = false
				if code == 1 and type(stderr) == "string" then
					for line in stderr:gmatch("[^\r\n]+") do
						if TextUtils.trim(line) == expected then absent = true end
					end
				end
				if not absent then
					probe.incomplete = true
				else
					probe.absent = probe.absent + 1
				end
			end
			probe.remaining = probe.remaining - 1
			if probe.remaining ~= 0 then return end
			cached_preferences = probe.values
			snapshot_incomplete = probe.incomplete
			snapshot_all_absent = probe.absent == #MACOS_PREFERENCE_COMMANDS
			snapshot_ready = true
			pending_probe = nil
			if snapshot_incomplete or (next(cached_preferences) == nil and not snapshot_all_absent) then
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
		if not ok or type(handle) ~= "table" then
			complete(-1, "")
		elseif pending_probe ~= probe then
			retire_probe_handle(handle)
		elseif type(handle.isSettled) ~= "function" or type(handle.start) ~= "function"
			or type(handle.terminate) ~= "function" then
			complete(-1, "")
		else
			local probed, already_settled = pcall(handle.isSettled)
			if not probed then
				start_refused = true
				retire_probe_handle(handle)
				complete(-1, "")
			elseif already_settled == true then
				complete(-1, "")
			else
				-- spawn only prepares the task: unstarted, no read ever completed, so no
				-- gesture macOS claims was greyed or held back (field report 2026-11-05)
				local started, admitted = pcall(handle.start)
				if not started or admitted ~= true then
					Logger.warn(LOG, "System gesture settings read '%s' could not start.", tostring(args[2]))
					start_refused = true
					retire_probe_handle(handle)
					complete(-1, "")
				end
			end
		end
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

--- Tells whether at least one alias was actually present in the snapshot.
local function preference_is_observed(keys, preferences)
	for _, key in ipairs(keys) do
		if type(preferences[key]) == "table" and #preferences[key] > 0 then return true end
	end
	return false
end

--- Whether one macOS policy is on: any observed non-zero value, all observed
--- values zero means off, and no value at all means the macOS default.
--- @param keys table Native aliases for one policy.
--- @param preferences table Cached native values.
--- @param absent_on boolean What an unwritten preference means.
--- @return boolean on
local function preference_on(keys, preferences, absent_on)
	local found = false
	for _, key in ipairs(keys) do
		for _, value in ipairs(preferences[key] or {}) do
			found = true
			if value ~= 0 then return true end
		end
	end
	if found then return false end
	return absent_on == true
end

--- Native dragging and swiping are independent policies, not aliases of each
--- other. A vertical swipe whose Dock switch is off does nothing in macOS.
--- @param grp table Gesture conflict group.
--- @param preferences table Cached native values.
--- @return boolean disabled
local function macos_gesture_is_disabled(grp, preferences)
	if grp.dock and not preference_on({ grp.dock.key }, preferences, grp.dock.absent_on) then
		return true
	end
	return preference_is_disabled(grp.preferences, preferences)
		and (not grp.drag_preferences or preference_is_disabled(grp.drag_preferences, preferences))
end

--- Whether the macOS gesture of a blocking group is on, with the macOS
--- defaults for unwritten preferences. A three-finger drag turns the
--- three-finger swipes into drags, so it takes them too.
--- @param grp table Gesture conflict group.
--- @param preferences table Cached native values.
--- @return boolean on
local function system_gesture_on(grp, preferences)
	if grp.drag_preferences and preference_on(grp.drag_preferences, preferences, false) then
		return true
	end
	if grp.dock and not preference_on({ grp.dock.key }, preferences, grp.dock.absent_on) then
		return false
	end
	return preference_on(grp.preferences, preferences, grp.absent_on == true)
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
	if not snapshot_incomplete and macos_gesture_is_disabled(grp, cached_preferences) then
		if logged_posture[grp.key] ~= "disabled" then
			logged_posture[grp.key] = "disabled"
			Logger.debug(LOG, "Native macOS gesture '%s' is disabled — conflict warning suppressed.", grp.key)
		end
		return nil
	end

	-- An expected condition: the user bound a gesture macOS also uses, and the
	-- caller shows the notice. Log it once per posture change, not per query.
	if logged_posture[grp.key] ~= "conflict" then
		logged_posture[grp.key] = "conflict"
		Logger.info(LOG, "Native macOS gesture '%s' is enabled and overlaps slot %s.", grp.key, slot)
	end

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
	M.start_watch()
	return M.refresh(function()
		if boot_notified or not is_enabled or is_enabled() ~= true then return end
		boot_notified = true
		-- Nothing read: nothing to claim. A slot macOS holds is greyed in the
		-- menu and never fired, so "both will react" would be false for it;
		-- once the read ran, the boot showed five such dialogs (2026-11-05).
		if next(cached_preferences) == nil then return end
		for _, warning in ipairs(M.active_conflicts(active_actions)) do
			local group = KEY_TO_GROUP[warning.key]
			if not (group and group.blocks == true) then
				require("ui.gesture_conflict_notice").show(warning)
			end
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

--- Whether macOS itself uses a slot's gesture right now.
--- "taken": the macOS gesture is on, so the slot is greyed and never fired;
--- "unverified": the read completed but returned nothing, so it is held too;
--- "free": no blocking macOS gesture, or nothing read yet (the boot read).
--- @param slot string Gesture slot identifier.
--- @return string state "free", "taken" or "unverified".
function M.slot_system_state(slot)
	if not snapshot_ready then return "free" end
	local grp = SLOT_TO_GROUP[slot]
	if not grp or grp.blocks ~= true then return "free" end
	if next(cached_preferences) == nil and not snapshot_all_absent then return "unverified" end
	if system_gesture_on(grp, cached_preferences) then return "taken" end
	if grp.drag_preferences then
		local swipe_known = preference_is_observed(grp.preferences, cached_preferences)
		local drag_known = preference_is_observed(grp.drag_preferences, cached_preferences)
		-- The warning policy requires both independent settings before it calls
		-- either explicitly disabled setting conflict-free. Keep the engine held
		-- under the same uncertainty; when both are absent their defaults apply.
		if swipe_known ~= drag_known then return "unverified" end
	end
	return snapshot_incomplete and "unverified" or "free"
end

--- Whether the engine must hold a slot back; a cheap table read, safe on the
--- touch path.
--- @param slot string Gesture slot identifier.
--- @return boolean held
function M.slot_held_by_system(slot)
	return M.slot_system_state(slot) ~= "free"
end

--- The macOS gesture that takes a slot, for the Infos dialog and the log.
--- @param slot string Gesture slot identifier.
--- @return string|nil description
function M.slot_system_gesture(slot)
	local grp = SLOT_TO_GROUP[slot]
	return grp and grp.blocks == true and grp.description or nil
end

--- The state of every blocking slot, to compare two reads.
--- @return string digest
local function state_digest()
	local parts = {}
	for _, grp in ipairs(MACOS_GESTURE_GROUPS) do
		if grp.blocks == true then
			parts[#parts + 1] = grp.key .. "=" .. M.slot_system_state(grp.slots[1])
		end
	end
	return table.concat(parts, ",")
end

--- Reads the preferences again and tells the listener when a slot changed
--- state, so the menu greys or restores it without a reload.
--- @return boolean accepted
function M.recheck()
	if recheck_pending then return true end
	recheck_pending = true
	local before = state_digest()
	local accepted = M.refresh(function()
		recheck_pending = false
		if state_digest() == before then return end
		Logger.info(LOG, "System gesture settings changed: %s.", state_digest())
		if type(state_listener) == "function" then
			local ok, err = xpcall(state_listener, debug.traceback)
			if not ok then Logger.error(LOG, "Gesture state listener failed: %s.", tostring(err)) end
		end
	end)
	if not accepted then recheck_pending = false end
	return accepted
end

--- Names who hears a slot change state (the menu's rebuild request).
--- @param listener function|nil Called with no argument after a change.
function M.set_state_listener(listener)
	state_listener = type(listener) == "function" and listener or nil
end

--- Re-reads the preferences on a slow timer, off the touch path: a `defaults
--- read` per domain, never a watcher on the hot path.
--- @param scheduler table|nil TimerScheduler-like { every, cancel } (tests).
--- @return boolean started
function M.start_watch(scheduler)
	if watch_handle and watch_handle.active then return true end
	if watch_handle and M.stop_watch() ~= true then return false end
	local timers = scheduler or require("core.events.timer_scheduler")
	local watch = { timers = timers, active = false, starting = true }
	watch_handle = watch
	local ok, handle, committed = pcall(timers.every, Timings.sec("gestures", "system_prefs_recheck_ms"),
		function() if watch_handle == watch and watch.active then M.recheck() end end)
	watch.starting = false
	if not ok or not handle or committed ~= true then
		if type(handle) == "table" and handle.timer ~= nil then
			watch.handle = handle
		elseif watch_handle == watch then
			watch_handle = nil
		end
		Logger.error(LOG, "The system gesture settings recheck could not be scheduled.")
		return false
	end
	if watch.cancelled then
		watch.handle = handle
		M.stop_watch()
		return false
	end
	watch.handle, watch.active = handle, true
	Logger.debug(LOG, "System gesture settings recheck armed.")
	return true
end

--- Stops the recheck timer.
function M.stop_watch()
	local watch = watch_handle
	if not watch then return true end
	watch.active = false
	watch.cancelled = true
	if watch.starting then return false end
	local ok, cancelled = pcall(watch.timers.cancel, watch.handle)
	if not ok or cancelled ~= true then
		Logger.error(LOG, "The system gesture settings recheck remains pending cleanup.")
		return false
	end
	if watch_handle == watch then watch_handle = nil end
	return true
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
	local timer_settled = M.stop_watch()
	recheck_pending = false
	local probe = pending_probe
	pending_probe = nil
	if probe then
		-- A quit or a reload during the boot read: nothing is lost, the next
		-- start reads the settings again, so no warning (#99 logged three)
		Logger.info(LOG, "System gesture settings read cancelled during shutdown.")
		for _, handle in ipairs(probe.handles) do
			if type(handle.isSettled) == "function" and type(handle.terminate) == "function" then
				retire_probe_handle(handle)
			end
		end
	end
	return retry_probe_cleanup() and timer_settled == true
end

return M
