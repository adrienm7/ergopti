-- Script control shortcuts:
--   AltGr (Right Option) + Return    : toggle pause / resume all modules
--   AltGr (Right Option) + Backspace : reload the Hammerspoon configuration

local M = {}
local utils = require("utils")

local is_paused = false
local tap = nil

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

local function handle_key(e)
	if not is_right_alt_only(e) then return false end

	local code = e:getKeyCode()

	-- AltGr + Return : toggle pause / resume
	if code == KEYCODE_RETURN then
		if is_paused then
			resume_all()
			is_paused = false
			utils.notify("Script réactivé ▶")
		else
			pause_all()
			is_paused = true
			utils.notify("Script mis en pause ⏸")
		end
		return true  -- consume the event
	end

	-- AltGr + Backspace : reload the entire configuration
	if code == KEYCODE_BACKSPACE then
		utils.notify("Rechargement du script… 🔄")
		-- Small delay so the notification has time to appear before reload
		hs.timer.doAfter(0.3, function() hs.reload() end)
		return true  -- consume the event
	end

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

return M
