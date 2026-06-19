--- adapters/key_state.lua

--- ==============================================================================
--- MODULE: KeyState Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the KeyState port contract defined in
--- static/ergopti_plus/shared/ports/KeyState.spec.js. Wraps hs.eventtap to query
--- the physical state of keyboard keys without coupling domain modules to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: isDown() returns false and isUp() returns true on
---    any error, matching the port contract error_behavior ("absent key = up").
--- 2. Defensive pcall: hs.eventtap calls are wrapped to prevent propagation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.key_state"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

-- Normalisation map: platform-specific sided key names → canonical modifier name
-- used by hs.eventtap.checkKeyboardModifiers(). checkKeyboardModifiers() only
-- returns modifier flags (shift/ctrl/alt/cmd/fn); it cannot distinguish sides,
-- so we collapse left/right variants to the canonical name (H4 audit fix).
local KEY_NORMALISATION = {
	LShift = "shift",  RShift = "shift",
	LCtrl  = "ctrl",   RCtrl  = "ctrl",
	LAlt   = "alt",    RAlt   = "alt",
	LCmd   = "cmd",    RCmd   = "cmd",
}

--- Normalises a platform key name to the canonical modifier name expected by
--- hs.eventtap.checkKeyboardModifiers(). Unknown names are returned unchanged.
--- @param key_name string The raw key name to normalise.
--- @return string The normalised name.
local function normalize_key(key_name)
	return KEY_NORMALISATION[key_name] or key_name
end

--- Returns true when the key is physically held down.
--- @param key_name string Platform key identifier (e.g. "shift", "ctrl", "LShift").
--- @return boolean
function M.isDown(key_name)
	local ok, result = pcall(function()
		local flags = hs.eventtap and hs.eventtap.checkKeyboardModifiers
			and hs.eventtap.checkKeyboardModifiers()
		if type(flags) == "table" then
			return flags[normalize_key(key_name)] == true
		end
		return false
	end)
	if not ok then
		Logger.error(LOG, "isDown(): error checking %q — %s", tostring(key_name), tostring(result))
		return false
	end
	return result == true
end

--- Returns true when the key is not physically held down.
--- @param key_name string Platform key identifier.
--- @return boolean
function M.isUp(key_name)
	return not M.isDown(key_name)
end

--- Returns true when a right-hand AltGr modifier (right command OR right option)
--- is physically held at this instant. Unlike isDown(), this uses the
--- device-specific raw flag masks so a LEFT command/option is correctly excluded
--- — required by the script-control sentinel guard, which must accept a genuine
--- right-AltGr + key chord but reject a bare function key or a left-modifier
--- chord. Falls back to the side-agnostic command/option flags only when the raw
--- masks are unavailable (never on real macOS), so a bare key can still never pass.
--- @return boolean True if right command or right option is currently down.
function M.is_right_altgr_held()
	local ok, result = pcall(function()
		if not (hs.eventtap and hs.eventtap.checkKeyboardModifiers) then return false end
		local mods = hs.eventtap.checkKeyboardModifiers(true)
		if type(mods) ~= "table" then return false end

		local raw   = mods._raw
		local masks = hs.eventtap.event and hs.eventtap.event.rawFlagMasks
		if type(raw) == "number" and type(masks) == "table" then
			local right_cmd = masks.deviceRightCommand   or 0
			local right_opt = masks.deviceRightAlternate or 0
			return (raw & right_cmd) ~= 0 or (raw & right_opt) ~= 0
		end
		return mods.cmd == true or mods.alt == true
	end)
	if not ok then
		Logger.error(LOG, "is_right_altgr_held(): %s", tostring(result))
		return false
	end
	return result == true
end

return M
