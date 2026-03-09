-- Script control shortcuts:
--   AltGr (Right Option) + Return    : toggle pause / resume all modules
--   AltGr (Right Option) + Backspace : reload the Hammerspoon configuration

local M = {}
local utils = require("lib.utils")

local is_paused = false
local tap        = nil

-- Configurable: maps key name → action string (can be changed after start())
local _key_actions     = { return_key = "pause", backspace = "reload" }
local _on_pause_change = nil  -- callback(is_paused) called on pause state change
local _extras          = {}   -- handlers for actions this module cannot run alone

-- Available actions and their display labels (also exposed as M.ACTIONS / M.ACTION_LABELS)
local ACTION_LABELS = {
	none      = "Désactivé",
	pause     = "Pause / Reprendre",
	reload    = "Recharger le script",
	open_init = "Ouvrir init.lua",
	open_ahk  = "Ouvrir le script AHK",
}
local ACTIONS_ORDER = { "none", "pause", "reload", "open_init", "open_ahk" }

-- ── Modifier detection ────────────────────────────────────────────────────────

-- Return true when the event has exclusively the right Option key held down
-- (no left Option, no Cmd, no Ctrl, no Shift).
local function is_right_alt_only(e)
	local flags = e:getFlags()
	-- Standard check: alt must be set; no other common modifiers
	if not flags.alt or flags.cmd or flags.ctrl or flags.shift then
		return false
	end
	-- Device-level check: ensure it is the physical right Option key
	local raw = e:rawFlags()
	local masks = hs.eventtap.event.rawFlagMasks
	local right_mask = masks and masks.deviceRightAlternate or 0
	local left_mask  = masks and masks.deviceLeftAlternate  or 0
	-- If masks are unavailable we cannot distinguish sides; accept any alt.
	if right_mask == 0 then return true end
	return (raw & right_mask) ~= 0 and (raw & left_mask) == 0
end

-- ── Module lifecycle ──────────────────────────────────────────────────────────

local _keymap    = nil
local _shortcuts = nil
local _gestures  = nil
local _scroll    = nil

local function pause_all()
	-- Use pause_processing() instead of stop() so the keymap eventtap stays
	-- alive. This guarantees that script_control's own shortcuts remain
	-- reachable even while the script appears "paused".
	if _keymap    then pcall(function() _keymap.pause_processing()  end) end
	if _shortcuts then pcall(function() _shortcuts.stop()           end) end
	if _gestures  then pcall(function() _gestures.disable_all()     end) end
	if _scroll    then pcall(function() _scroll.stop()              end) end
end

local function resume_all()
	if _keymap    then pcall(function() _keymap.resume_processing() end) end
	if _shortcuts then pcall(function() _shortcuts.start()          end) end
	if _gestures  then pcall(function() _gestures.enable_all()      end) end
	if _scroll    then pcall(function() _scroll.start()             end) end
end

-- ── Key handler ───────────────────────────────────────────────────────────────

local KEYCODE_RETURN    = 36
local KEYCODE_BACKSPACE = 51

-- Dispatch a configured action; returns true if the event should be consumed.
local function dispatch_action(action)
	if not action or action == "none" then return false end
	if action == "pause" then
		-- Update the icon immediately, before any heavy eventtap operation.
		is_paused = not is_paused
		if _on_pause_change then _on_pause_change(is_paused) end
		if is_paused then
			pause_all()
			utils.notify("Script mis en pause ⏸")
		else
			resume_all()
			utils.notify("Script réactivé ▶")
		end
		return true
	elseif action == "reload" then
		utils.notify("Rechargement du script… 🔄")
		hs.timer.doAfter(0.3, function() hs.reload() end)
		return true
	elseif action == "open_init" then
		if _extras.open_init then _extras.open_init() end
		return true
	elseif action == "open_ahk" then
		if _extras.open_ahk then _extras.open_ahk() end
		return true
	end
	return false
end

local function handle_key(e)
	if not is_right_alt_only(e) then return false end
	local code = e:getKeyCode()
	if code == KEYCODE_RETURN    then return dispatch_action(_key_actions.return_key) end
	if code == KEYCODE_BACKSPACE then return dispatch_action(_key_actions.backspace)  end
	return false
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start the script-control eventtap.
---
--- Args:
---     keymap:    The keymap module (must expose start() and stop()).
---     shortcuts: The shortcuts module (must expose start() and stop()).
---     gestures:  The gestures module (must expose enable_all() and disable_all()).
---     scroll:    The scroll module (must expose start() and stop()).
function M.start(keymap, shortcuts, gestures, scroll)
	_keymap    = keymap
	_shortcuts = shortcuts
	_gestures  = gestures
	_scroll    = scroll

	tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handle_key)
	pcall(function() tap:start() end)
end

function M.stop()
	if tap then
		pcall(function() tap:stop() end)
		tap = nil
	end
end

--- Return whether the script is currently paused.
function M.is_paused()
	return is_paused
end

--- Set the action triggered by a key slot.
--- keyname: "return_key" or "backspace"
--- action: one of "none", "pause", "reload", "open_init", "open_ahk"
function M.set_shortcut_action(keyname, action)
	_key_actions[keyname] = action
end

--- Register a callback invoked whenever the pause state changes.
--- cb(is_paused: boolean)
function M.set_on_pause_change(cb)
	_on_pause_change = cb
end

--- Provide handlers for actions that require external context.
--- tbl may contain: open_init(), open_ahk()
function M.set_extras(tbl)
	_extras = tbl or {}
end

-- Ordered list of action identifiers (for menu building).
M.ACTIONS = ACTIONS_ORDER

-- Map of action id → display label.
M.ACTION_LABELS = ACTION_LABELS

return M
