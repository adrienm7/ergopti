--- modules/shortcuts/script_control.lua

--- ==============================================================================
--- MODULE: Script Control
--- DESCRIPTION:
--- Manages global shortcuts for the Ergopti+ script lifecycle:
---  AltGr (Right Option) + Return    : Toggle pause / resume all modules
---  AltGr (Right Option) + Backspace : Reload the Hammerspoon configuration
---
--- FEATURES & RATIONALE:
--- 1. Safe Interactivity: Interacts safely with keymap, shortcuts, and gestures modules.
--- 2. OS Safety: Ensures no deadlocks occur when the script is logically paused.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")

local LOG = "shortcuts.script_control"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Ordered action definitions used by the menu UI
local ACTION_DEFINITIONS = {
	{ id = "none",               label = "Désactivé" },
	{ id = "pause",              label = "Pause / Reprendre" },
	{ id = "reload",             label = "Recharger" },
	{ id = "open_console",       label = "Console Hammerspoon" },
	{ id = "quit_hammerspoon",   label = "Quitter Hammerspoon" },
	{ id = "open_init",          label = "Ouvrir init.lua" },
	{ id = "open_ahk",           label = "Ouvrir le fichier AHK" },
	{ id = "open_personal_toml", label = "Ouvrir le fichier custom.toml" },
	{ id = "open_config",        label = "Ouvrir config.json" },
	{ id = "open_logs",          label = "Ouvrir le dossier de logs" },
	{ id = "add_hotstring",      label = "Ajouter un hotstring" },
	{ id = "trigger_prediction", label = "Déclencher une prédiction IA" },
	{ id = "show_metrics",       label = "Afficher les métriques de frappe" },
	{ id = "show_apps_time",     label = "Afficher le temps sur les applications" },
}

local ACTION_LABELS = {}
local ACTIONS_ORDER = {}

for _, definition in ipairs(ACTION_DEFINITIONS) do
	ACTION_LABELS[definition.id] = definition.label
	table.insert(ACTIONS_ORDER, definition.id)
end

local KEYCODE_RETURN    = 36
local KEYCODE_BACKSPACE = 51

local _is_paused       = false
local _tap             = nil
local _key_actions     = { return_key = "pause", backspace = "reload" }
local _on_pause_change = nil
local _extras          = {}

local _keymap          = nil
local _shortcuts       = nil
local _gestures        = nil





-- =====================================
-- =====================================
-- ======= 2/ Modifier Detection =======
-- =====================================
-- =====================================

--- Returns true when the event has exclusively the right Option key held down.
--- (no left Option, no Cmd, no Ctrl, no Shift).
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True if only right Alt is pressed.
local function is_right_alt_only(e)
	if type(e) ~= "userdata" or type(e.getFlags) ~= "function" then return false end
	
	local ok_flags, flags = pcall(function() return e:getFlags() end)
	if not ok_flags or type(flags) ~= "table" then return false end
	
	-- Standard check: alt must be set; no other common modifiers
	if not flags.alt or flags.cmd or flags.ctrl or flags.shift then
		return false
	end
	
	-- Device-level check: ensure it is the physical right Option key
	local ok_raw, raw = pcall(function() return e:rawFlags() end)
	if not ok_raw or type(raw) ~= "number" then return true end -- Fallback if rawFlags fails
	
	local masks = hs.eventtap.event.rawFlagMasks
	if type(masks) ~= "table" then return true end -- Fallback if masks are unavailable
	
	local right_mask = masks.deviceRightAlternate or 0
	local left_mask  = masks.deviceLeftAlternate  or 0
	
	-- If masks are totally unavailable we cannot distinguish sides; accept any alt
	if right_mask == 0 then return true end
	
	return (raw & right_mask) ~= 0 and (raw & left_mask) == 0
end





-- ==============================
-- ==============================
-- ======= 3/ Core Engine =======
-- ==============================
-- ==============================

--- Suspends all registered modules gracefully.
local function pause_all()
	-- Use pause_processing() instead of stop() so the keymap eventtap stays
	-- alive. This guarantees that script_control’s own shortcuts remain
	-- reachable even while the script appears paused.
	if _keymap and type(_keymap.pause_processing) == "function" then 
		pcall(function() _keymap.pause_processing() end) 
	end
	
	if _shortcuts and type(_shortcuts.stop) == "function" then 
		pcall(function() _shortcuts.stop() end) 
	end
	
	if _gestures and type(_gestures.disable_all) == "function" then 
		pcall(function() _gestures.disable_all() end) 
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
end

--- Dispatches a configured action.
--- @param action string The action identifier.
--- @return boolean True if the event should be consumed.
local function dispatch_action(action)
	if type(action) ~= "string" or action == "none" then return false end
	
	if action == "pause" then
		-- Update the internal state immediately before heavy operations
		_is_paused = not _is_paused
		
		if type(_on_pause_change) == "function" then 
			pcall(_on_pause_change, _is_paused) 
		end
		
		if _is_paused then
			Logger.info(LOG, "Pausing all script operations.")
			pause_all()
			notifications.notify("Script mis en pause ⏸")
		else
			Logger.info(LOG, "Resuming all script operations.")
			resume_all()
			notifications.notify("Script réactivé ▶")
		end
		return true
		
	elseif action == "reload" then
		Logger.info(LOG, "Triggering Hammerspoon configuration reload.")
		notifications.notify("Rechargement du script… 🔄")
		hs.timer.doAfter(0.3, function() pcall(hs.reload) end)
		return true
		
	elseif action == "open_init" then
		if type(_extras.open_init) == "function" then pcall(_extras.open_init) end
		return true
		
	elseif action == "open_ahk" then
		if type(_extras.open_ahk) == "function" then pcall(_extras.open_ahk) end
		return true

	elseif action == "open_personal_toml" then
		if type(_extras.open_personal_toml) == "function" then pcall(_extras.open_personal_toml) end
		return true
		
	elseif action == "trigger_prediction" then
		if type(_extras.trigger_prediction) == "function" then pcall(_extras.trigger_prediction) end
		return true
		
	elseif action == "add_hotstring" then
		if type(_extras.add_hotstring) == "function" then pcall(_extras.add_hotstring) end
		return true
		
	elseif action == "show_metrics" then
		if type(_extras.show_metrics) == "function" then pcall(_extras.show_metrics) end
		return true
		
	elseif action == "show_apps_time" then
		if type(_extras.show_apps_time) == "function" then pcall(_extras.show_apps_time) end
		return true

	elseif action == "open_config" then
		if type(_extras.open_config) == "function" then pcall(_extras.open_config) end
		return true
		
	elseif action == "open_logs" then
		if type(_extras.open_logs) == "function" then pcall(_extras.open_logs) end
		return true
		
	elseif action == "open_console" then
		pcall(hs.openConsole)
		return true
		
	elseif action == "quit_hammerspoon" then
		Logger.info(LOG, "Shutting down Hammerspoon.")
		hs.timer.doAfter(0.1, function() os.exit(0) end)
		return true
	end
	
	return false
end

--- Handles the low-level keystroke event.
--- @param e userdata The hs.eventtap.event object.
--- @return boolean True to consume the keystroke, false otherwise.
local function handle_key(e)
	if not is_right_alt_only(e) then return false end
	
	local ok, code = pcall(function() return e:getKeyCode() end)
	if not ok or type(code) ~= "number" then return false end
	
	if code == KEYCODE_RETURN then
		local ok_kl, kl = pcall(require, "modules.keylogger")
		if ok_kl and kl and type(kl.log_shortcut) == "function" then
			local app = hs.application.frontmostApplication()
			pcall(kl.log_shortcut, "Alt+Enter", app and app:title() or "Unknown")
		end
		return dispatch_action(_key_actions.return_key)
	end

	if code == KEYCODE_BACKSPACE then
		local ok_kl, kl = pcall(require, "modules.keylogger")
		if ok_kl and kl and type(kl.log_shortcut) == "function" then
			local app = hs.application.frontmostApplication()
			pcall(kl.log_shortcut, "Alt+Backspace", app and app:title() or "Unknown")
		end
		return dispatch_action(_key_actions.backspace)
	end
	
	return false
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

M.ACTIONS       = ACTIONS_ORDER
M.ACTION_LABELS = ACTION_LABELS

--- Starts the script-control eventtap.
--- @param keymap table The keymap module (must expose pause_processing and resume_processing).
--- @param shortcuts table The shortcuts module (must expose start and stop).
--- @param gestures table The gestures module (must expose enable_all and disable_all).
function M.start(keymap, shortcuts, gestures)
	Logger.debug(LOG, "Starting script control interception…")
	_keymap    = type(keymap) == "table" and keymap or nil
	_shortcuts = type(shortcuts) == "table" and shortcuts or nil
	_gestures  = type(gestures) == "table" and gestures or nil

	local ok, new_tap = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, handle_key)
	if ok and new_tap then
		_tap = new_tap
		pcall(function() _tap:start() end)
		Logger.info(LOG, "Script control started successfully.")
	else
		Logger.error(LOG, "Failed to start script control eventtap.")
	end
end

--- Stops the script-control eventtap.
function M.stop()
	Logger.debug(LOG, "Stopping script control interception…")
	if _tap and type(_tap.stop) == "function" then
		pcall(function() _tap:stop() end)
		_tap = nil
		Logger.info(LOG, "Script control stopped.")
	end
end

--- Returns whether the script is currently paused.
--- @return boolean True if paused.
function M.is_paused()
	return _is_paused
end

--- Sets the action triggered by a specific key slot.
--- @param keyname string "return_key" or "backspace".
--- @param action string One configured action id (for example "pause" or "open_personal_toml").
function M.set_shortcut_action(keyname, action)
	if type(keyname) == "string" and type(action) == "string" then
		_key_actions[keyname] = action
	end
end

--- Registers a callback invoked whenever the pause state changes.
--- @param cb function Called with (is_paused: boolean).
function M.set_on_pause_change(cb)
	if type(cb) == "function" then
		_on_pause_change = cb
	end
end

--- Provides handlers for actions that require external context (like paths).
--- @param tbl table May contain handlers such as open_init(), open_ahk(), and open_personal_toml().
function M.set_extras(tbl)
	_extras = type(tbl) == "table" and tbl or {}
end

return M
