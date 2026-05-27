--- adapters/window_info.lua

--- ==============================================================================
--- MODULE: WindowInfo Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the WindowInfo port contract defined in
--- static/ergopti_plus/shared/ports/WindowInfo.spec.js. Wraps hs.window and
--- hs.application behind the two canonical methods (getFocused, getAll) so
--- domain modules can query the focused window without coupling to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: getFocused() always returns a WindowInfo table, never
---    nil — all fields default to "" when the focused window cannot be queried
---    (screen locked, desktop in focus, permission denied).
--- 2. Bundle ID: macOS provides a bundle ID for every app via
---    hs.application:bundleID(). Windows has no equivalent; the field is ""
---    on that platform but is populated here on macOS.
--- 3. Defensive pcall: hs.window calls can raise on some internal states;
---    every call is wrapped in pcall to prevent propagation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.window_info"




-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Returns an empty WindowInfo table (all fields "").
local function empty_info()
	return { appId = "", windowTitle = "", bundleId = "", executablePath = "" }
end

--- Builds a WindowInfo table from an hs.window object.
--- @param win userdata hs.window instance.
--- @return table WindowInfo with populated fields.
local function info_from_window(win)
	local info = empty_info()
	if not win then return info end

	local ok_title, title = pcall(function() return win:title() end)
	if ok_title and type(title) == "string" then
		info.windowTitle = title
	end

	local ok_app, app = pcall(function() return win:application() end)
	if ok_app and app then
		local ok_name, name = pcall(function() return app:name() end)
		if ok_name and type(name) == "string" then
			info.appId = name
		end

		local ok_bundle, bundle = pcall(function() return app:bundleID() end)
		if ok_bundle and type(bundle) == "string" then
			info.bundleId = bundle
		end
	end

	return info
end




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Returns the identity of the currently focused window.
--- @return table WindowInfo: { appId, windowTitle, bundleId, executablePath }
function M.getFocused()
	local ok, result = pcall(function()
		local win = hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
		return info_from_window(win)
	end)

	if not ok then
		Logger.error(LOG, "getFocused(): unexpected error — %s", tostring(result))
		return empty_info()
	end
	return result or empty_info()
end

--- Returns an array of WindowInfo tables for all currently visible windows.
--- @return table Array of WindowInfo objects (may be empty).
function M.getAll()
	local ok, result = pcall(function()
		local windows = hs.window and hs.window.allWindows and hs.window.allWindows()
		if type(windows) ~= "table" then return {} end

		local infos = {}
		for _, win in ipairs(windows) do
			infos[#infos + 1] = info_from_window(win)
		end
		return infos
	end)

	if not ok then
		Logger.error(LOG, "getAll(): unexpected error — %s", tostring(result))
		return {}
	end
	return type(result) == "table" and result or {}
end

return M
