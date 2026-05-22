--- modules/shortcuts/script_control.lua

--- ==============================================================================
--- MODULE: Script Control
--- DESCRIPTION:
--- Manages global shortcuts for the Ergopti+ script lifecycle:
---   AltGr (Right Option) + Return    → Toggle pause / resume all modules.
---   AltGr (Right Option) + Backspace → Reload the Hammerspoon configuration.
---
--- Each key slot is configurable: the user can bind any of the 14 listed actions
--- to either key via the menu.
---
--- FEATURES & RATIONALE:
--- 1. Right-Alt Detection: Distinguishes the physical right Option key from the
---    left one using rawFlags, so left-Alt shortcuts in apps are never stolen.
--- 2. Safe Pause: Uses pause_processing() rather than stop() on the keymap so
---    the script-control eventtap itself stays reachable while paused.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local Keycodes      = require("lib.keycodes")
local i18n          = require("lib.i18n")

local Engine    = require("modules.gestures.engine")
local GestActions = require("modules.gestures.actions")

local LOG = "shortcuts.script_control"




-- ====================================
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

-- Sentinel keycodes emitted by Karabiner's script-control rules
-- (modules/karabiner/init.lua → build_script_control_sentinel_rules).
-- These fire ONLY when the user physically presses right_command + one of the
-- three target keys. Tap actions that happen to emit backspace/return/escape
-- (e.g. left_command tap → backspace) can NEVER activate these sentinels,
-- because rule outputs bypass Karabiner's rule engine.
local KEYCODE_RETURN_SENTINEL    = Keycodes.F13_KARABINER_RETURN
local KEYCODE_BACKSPACE_SENTINEL = Keycodes.F14_KARABINER_BACKSPACE
local KEYCODE_ESCAPE_SENTINEL    = Keycodes.F15_KARABINER_ESCAPE

-- Physical keycodes used in the Karabiner-paused fallback path below. When KE is
-- running the sentinels above are the sole dispatch mechanism; this fallback
-- only exists so the user can still un-pause by pressing right_command + key
-- when KE's altgr remap is gone.
local KEYCODE_BACKSPACE = Keycodes.BACKSPACE
local KEYCODE_RETURN    = Keycodes.RETURN
local KEYCODE_ESCAPE    = Keycodes.ESCAPE

-- Module-level state
local _is_paused       = false
local _tap             = nil
local _key_actions     = {return_key = "script_pause_toggle", backspace = "script_reload", escape = "script_quit"}
local _on_pause_change = nil
local _extras          = {}

local _keymap    = nil
local _shortcuts = nil
local _gestures  = nil
local _karabiner = nil




-- =====================================
-- =====================================
-- ======= 2/ Modifier Detection ========
-- =====================================
-- =====================================

--- Returns true when the event carries ONLY the right_command modifier — the
--- KE-paused fallback path. When KE is running, right_command is remapped to
--- right_option and physical script-control dispatch goes through the sentinel
--- keycodes emitted by KE (F18/F19/F20). When KE is paused/killed the remap is
--- gone, physical right_command fires as cmd, and this predicate lets the user
--- still un-pause via the old right_cmd + key combination.
--- Rejects any event that also has alt/ctrl/shift or left_command held.
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True if the event is exactly right_command + key.
local function is_right_cmd_only(e)
	if type(e) ~= "userdata" or type(e.getFlags) ~= "function" then return false end

	local ok_flags, flags = pcall(function() return e:getFlags() end)
	if not ok_flags or type(flags) ~= "table" then return false end

	if flags.alt or flags.ctrl or flags.shift or not flags.cmd then return false end

	local ok_raw, raw = pcall(function() return e:rawFlags() end)
	local masks = (ok_raw and type(raw) == "number") and hs.eventtap.event.rawFlagMasks or nil
	if not masks then return false end

	local right_cmd = masks.deviceRightCommand or 0
	local left_cmd  = masks.deviceLeftCommand  or 0
	if right_cmd == 0 then return false end
	return (raw & right_cmd) ~= 0 and (raw & left_cmd) == 0
end




-- ==============================
--- ==============================
-- ======= 3/ Core Engine =======
--- ==============================
-- ==============================

--- Suspends all registered modules gracefully.
--- Uses pause_processing() on keymap so the script-control tap stays alive,
--- allowing the user to un-pause without reloading.
local function pause_all()
	if _keymap and type(_keymap.pause_processing) == "function" then
		pcall(function() _keymap.pause_processing() end)
	end
	if _shortcuts and type(_shortcuts.stop) == "function" then
		pcall(function() _shortcuts.stop() end)
	end
	if _gestures and type(_gestures.disable_all) == "function" then
		pcall(function() _gestures.disable_all() end)
	end
	if _karabiner and type(_karabiner.pause) == "function" then
		pcall(function() _karabiner.pause() end)
	end
end

--- Resumes all registered modules gracefully.
local function resume_all()
	if _keymap and type(_keymap.resume_processing) == "function" then
		pcall(function() _keymap.resume_processing() end)
	end
	if _shortcuts and type(_shortcuts.start) == "function" then
		pcall(function() _shortcuts.start() end)
	end
	if _gestures and type(_gestures.enable_all) == "function" then
		pcall(function() _gestures.enable_all() end)
	end
	if _karabiner and type(_karabiner.resume) == "function" then
		pcall(function() _karabiner.resume() end)
	end
end

--- Dispatches a configured action by its identifier.
--- @param action string The action id (e.g. "pause", "reload", "open_init").
--- @return boolean True if the originating keystroke should be consumed.
--- Calls _extras[name] when present. Used as the fallback path for actions
--- that need a context handler the script_control module doesn't own
--- (file paths, hotstring editor, metrics windows, …).
--- @param name string The extras key.
--- @return boolean true if the handler ran (or returned without error).
local function call_extra(name)
	if type(_extras[name]) == "function" then
		pcall(_extras[name])
	else
		Logger.debug(LOG, "Action '%s' has no registered handler in extras.", name)
	end
	return true
end

local function dispatch_action(action)
	if type(action) ~= "string" or action == "none" or action == "--" then return false end

	if action == "script_pause_toggle" then
		_is_paused = not _is_paused

		if type(_on_pause_change) == "function" then
			pcall(_on_pause_change, _is_paused)
		end

		if _is_paused then
			Logger.info(LOG, "Pausing all script operations.")
			pause_all()
			notifications.notify(i18n.get("script_control.paused"), nil, "warning")
		else
			Logger.info(LOG, "Resuming all script operations.")
			resume_all()
			notifications.notify(i18n.get("script_control.resumed"), nil, "success")
		end
		return true
	end

	-- Use centralized action dispatcher for everything else
	Logger.debug(LOG, "Dispatching centralized action: %s…", action)
	pcall(GestActions.execute_single, action)
	return true
end

--- Logs a shortcut activation via the keylogger if available.
--- @param label string Human-readable shortcut label for the log.
local function log_shortcut_if_available(label)
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.log_shortcut) == "function" then
		local app = hs.application.frontmostApplication()
		pcall(kl.log_shortcut, label, app and app:title() or "Unknown")
	end
end

--- Handles incoming keyDown events; consumes the event when it matches a configured slot.
---
--- Two independent dispatch paths:
---   1. Sentinel keycodes (F13/F14/F15) — emitted by Karabiner's script-control
---      rules on physical right_command + return/backspace/escape. This is the
---      primary path when KE is running and cannot be spoofed by tap actions,
---      because KE rule outputs bypass further rule matching.
---   2. Right-command fallback — when KE is paused/killed, physical right_command
---      fires as cmd (not alt), so we accept rcmd + backspace/return/escape
---      directly so the user can still un-pause without reloading.
---
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True to consume the keystroke, false to pass it through.
local function handle_key(e)
	local ok, code = pcall(function() return e:getKeyCode() end)
	if not ok or type(code) ~= "number" then return false end

	-- Primary path: sentinel keycodes from KE's script-control rules.
	if code == KEYCODE_BACKSPACE_SENTINEL then
		log_shortcut_if_available("Alt+Backspace")
		dispatch_action(_key_actions.backspace)
		return true
	end
	if code == KEYCODE_RETURN_SENTINEL then
		log_shortcut_if_available("Alt+Enter")
		dispatch_action(_key_actions.return_key)
		return true
	end
	if code == KEYCODE_ESCAPE_SENTINEL then
		log_shortcut_if_available("Alt+Escape")
		dispatch_action(_key_actions.escape)
		return true
	end

	-- Fallback path: KE paused — physical right_command + target key.
	if not is_right_cmd_only(e) then return false end

	if code == KEYCODE_BACKSPACE then
		log_shortcut_if_available("Alt+Backspace")
		return dispatch_action(_key_actions.backspace)
	end
	if code == KEYCODE_RETURN then
		log_shortcut_if_available("Alt+Enter")
		return dispatch_action(_key_actions.return_key)
	end
	if code == KEYCODE_ESCAPE then
		log_shortcut_if_available("Alt+Escape")
		return dispatch_action(_key_actions.escape)
	end

	return false
end




-- =============================
--- =============================
-- ======= 4/ Public API =======
--- =============================
-- =============================

M.ACTIONS = GestActions.SG_NAMES

-- Build a flat id→label lookup from SG_NAMES, skipping separators and headers.
do
	local labels = {}
	if type(M.ACTIONS) == "table" then
		for _, id in ipairs(M.ACTIONS) do
			if type(id) == "string" and id ~= "-" and id ~= "--" and id:sub(1, 1) ~= "#" then
				labels[id] = GestActions.get_label(id)
			end
		end
	end
	M.ACTION_LABELS = labels
end

--- Retrieves the localized label for a given action ID.
--- @param name string The action ID.
--- @return string The human-readable label.
function M.get_action_label(name)
	if GestActions and type(GestActions.get_label) == "function" then
		return GestActions.get_label(name)
	end
	return name
end

--- Starts the script-control eventtap with references to sibling modules.
--- @param keymap table Keymap module (must expose pause_processing / resume_processing).
--- @param shortcuts table Shortcuts module (must expose start / stop).
--- @param gestures table Gestures module (must expose enable_all / disable_all).
--- @param karabiner table|nil Optional Karabiner module (must expose pause / resume).
function M.start(keymap, shortcuts, gestures, karabiner)
	Logger.start(LOG, "Starting script control…")

	_keymap    = type(keymap)    == "table" and keymap    or nil
	_shortcuts = type(shortcuts) == "table" and shortcuts or nil
	_gestures  = type(gestures)  == "table" and gestures  or nil
	_karabiner = type(karabiner) == "table" and karabiner or nil

	if not _keymap    then Logger.warn(LOG, "M.start(): keymap module not provided — pause/resume will be partial.") end
	if not _shortcuts then Logger.warn(LOG, "M.start(): shortcuts module not provided — pause/resume will be partial.") end
	if not _gestures  then Logger.warn(LOG, "M.start(): gestures module not provided — pause/resume will be partial.") end

	local ok, new_tap = pcall(hs.eventtap.new, {hs.eventtap.event.types.keyDown}, handle_key)
	if not ok or not new_tap then
		Logger.error(LOG, "Failed to create script-control eventtap.")
		return
	end

	_tap = new_tap
	pcall(function() _tap:start() end)
	Logger.success(LOG, "Script control started.")
end

--- Stops the script-control eventtap.
function M.stop()
	Logger.start(LOG, "Stopping script control…")

	if not _tap then
		Logger.debug(LOG, "M.stop(): eventtap was not running — nothing to do.")
		Logger.success(LOG, "Script control stopped.")
		return
	end

	if type(_tap.stop) == "function" then
		pcall(function() _tap:stop() end)
	end
	_tap = nil

	Logger.success(LOG, "Script control stopped.")
end

--- Returns whether the script is currently paused.
--- @return boolean True if paused.
function M.is_paused()
	return _is_paused
end

--- Configures the action triggered by a specific key slot.
--- @param keyname string "return_key", "backspace", or "escape".
--- @param action string One of the recognised action ids.
function M.set_shortcut_action(keyname, action)
	if type(keyname) ~= "string" or type(action) ~= "string" then
		Logger.error(LOG, "set_shortcut_action(): both keyname and action must be strings.")
		return
	end
	_key_actions[keyname] = action
	Logger.debug(LOG, "Key slot '%s' → '%s'.", keyname, action)
end

--- Registers a callback invoked whenever the pause state changes.
--- @param cb function Called with (is_paused: boolean).
function M.set_on_pause_change(cb)
	if type(cb) ~= "function" then
		Logger.error(LOG, "set_on_pause_change(): argument must be a function.")
		return
	end
	_on_pause_change = cb
	Logger.debug(LOG, "Pause-change callback registered.")
end

--- Provides handlers for actions that require external context (file paths, UI windows, …).
--- Recognised keys mirror the ids in ACTION_DEFINITIONS for the categories
--- that script_control delegates rather than handles in-line:
---   open_paths_editor, open_hotstrings_editor,
---   open_metrics_typing, open_metrics_apps,
---   open_script_source, open_personal_shortcuts,
---   open_personal_hotstrings, open_personal_info,
---   open_config, open_logs_folder, open_today_log,
---   add_hotstring, trigger_prediction.
--- Keys with no handler are quietly skipped (debug log) so the right-Alt key
--- slots and gestures stay assignable on a fresh install.
function M.set_extras(tbl)
	if type(tbl) ~= "table" then
		Logger.error(LOG, "set_extras(): argument must be a table.")
		return
	end
	_extras = tbl
	local count = 0
	for _ in pairs(tbl) do count = count + 1 end
	Logger.debug(LOG, "Extras table registered (%d handler(s)).", count)
end

--- Programmatically toggles the paused state (same as pressing the configured key).
function M.toggle()
	Logger.debug(LOG, "Programmatic pause toggle requested.")
	pcall(dispatch_action, "script_pause_toggle")
end

return M
