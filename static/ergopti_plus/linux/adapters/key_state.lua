--- linux/adapters/key_state.lua

--- ==============================================================================
--- MODULE: KeyState Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the KeyState port contract defined in
--- static/ergopti_plus/shared/ports/KeyState.spec.js. Queries the physical
--- state of keyboard modifier keys via xdotool/xinput without coupling domain
--- modules to platform-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: KS_IsDown() returns false and KS_IsUp() returns true
---    on any error, matching the port contract error_behavior ("absent key = up").
--- 2. xdotool getactivewindow getmodifiers: the quickest cross-compositor way
---    to read modifier state without requiring root or a kernel event tap.
--- 3. Key name normalization: maps canonical names (shift, ctrl, alt, cmd/super)
---    to the X11 modifier mask strings returned by xdotool.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.key_state"


-- ==========================================
-- ==========================================
-- ======= 1/ Internal Helpers =============
-- ==========================================
-- ==========================================

-- Mapping from canonical port key names to xdotool modifier strings
local KEY_NAME_MAP = {
	shift  = "shift",
	ctrl   = "ctrl",
	control= "ctrl",
	alt    = "alt",
	cmd    = "super",
	super  = "super",
	meta   = "super",
	fn     = nil,     -- no reliable X11 mapping
}

--- Returns the xdotool modifier string for a canonical key name.
--- @param key_name string
--- @return string|nil
local function _normalize(key_name)
	if type(key_name) ~= "string" then return nil end
	return KEY_NAME_MAP[key_name:lower()]
end

--- Reads current X11 modifier state via xdotool.
--- Returns a string containing active modifier names (e.g. "shift ctrl"), or nil.
local function _read_modifiers()
	local fh = io.popen("xdotool getactivewindow getmodifiers 2>/dev/null", "r")
	if not fh then return nil end
	local out = fh:read("*a")
	fh:close()
	return type(out) == "string" and out:lower() or nil
end




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Returns true when the key is physically held down.
--- @param key_name string Canonical key name (shift, ctrl, alt, cmd, super).
--- @return boolean
function M.KS_IsDown(key_name)
	local mod = _normalize(key_name)
	if not mod then return false end
	local ok, result = pcall(function()
		local mods = _read_modifiers()
		if type(mods) ~= "string" then return false end
		return mods:find(mod, 1, true) ~= nil
	end)
	if not ok then
		Logger.error(LOG, "KS_IsDown(): error checking %q — %s",
			tostring(key_name), tostring(result))
		return false
	end
	return result == true
end

--- Returns true when the key is not physically held down.
--- @param key_name string Canonical key name.
--- @return boolean
function M.KS_IsUp(key_name)
	return not M.KS_IsDown(key_name)
end

return M
