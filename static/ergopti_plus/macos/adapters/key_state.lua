--- adapters/key_state.lua

--- ==============================================================================
--- MODULE: KeyState Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the KeyState port contract defined in
--- static/ergopti_plus/shared/ports/KeyState.spec.js. Wraps hs.eventtap to query
--- the physical state of keyboard keys without coupling domain modules to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: KS_IsDown() returns false and KS_IsUp() returns true on
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

--- Returns true when the key is physically held down.
--- @param key_name string Platform key identifier (e.g. "shift", "ctrl", "cmd").
--- @return boolean
function M.KS_IsDown(key_name)
	local ok, result = pcall(function()
		local flags = hs.eventtap and hs.eventtap.checkKeyboardModifiers
			and hs.eventtap.checkKeyboardModifiers()
		if type(flags) == "table" then
			return flags[key_name] == true
		end
		return false
	end)
	if not ok then
		Logger.error(LOG, "KS_IsDown(): error checking %q — %s", tostring(key_name), tostring(result))
		return false
	end
	return result == true
end

--- Returns true when the key is not physically held down.
--- @param key_name string Platform key identifier.
--- @return boolean
function M.KS_IsUp(key_name)
	return not M.KS_IsDown(key_name)
end

return M
