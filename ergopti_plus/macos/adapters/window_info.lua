--- adapters/window_info.lua

--- ==============================================================================
--- MODULE: WindowInfo Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the WindowInfo port contract defined in
--- static/ergopti_plus/_shared/core/ports/WindowInfo.spec.js. Wraps hs.window and
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
local Logger = require("infra.logger")

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

--- Returns the frontmost application's process id and bundle identifier. Not
--- part of the WindowInfo port: a caller reads it before a dialog of the
--- driver takes the front. Read from NSWorkspace, never through the
--- accessibility API, so an application that does not answer (a beachball)
--- or has no window is still read, and the read never waits on it.
--- @return table|nil application { pid, bundle_id }; nil when unreadable, or
--- when the application has no bundle identifier.
function M.frontmost_application()
	local ok, result = pcall(function()
		local app = hs.application and hs.application.frontmostApplication
			and hs.application.frontmostApplication()
		if not app then return nil end
		local pid, bundle_id = app:pid(), app:bundleID()
		if type(pid) ~= "number" or type(bundle_id) ~= "string" or bundle_id == "" then return nil end
		return { pid = pid, bundle_id = bundle_id }
	end)
	if not ok then
		Logger.error(LOG, "frontmost_application(): unexpected error — %s", tostring(result))
		return nil
	end
	return result
end

--- Returns the bundle identifier of the application a process id runs, from
--- NSWorkspace like frontmost_application. Not part of the WindowInfo port: a
--- caller checks that a process read earlier is still the same application.
--- @param pid number Process id.
--- @return string|nil bundle_id Nil when no application runs under that pid.
function M.application_bundle_id(pid)
	if type(pid) ~= "number" then error("application_bundle_id: pid must be a number", 2) end
	local ok, result = pcall(function()
		local app = hs.application and hs.application.applicationForPID
			and hs.application.applicationForPID(pid)
		if not app then return nil end
		local bundle_id = app:bundleID()
		if type(bundle_id) ~= "string" or bundle_id == "" then return nil end
		return bundle_id
	end)
	if not ok then
		Logger.error(LOG, "application_bundle_id(): unexpected error — %s", tostring(result))
		return nil
	end
	return result
end

--- Returns an identity of the focused window that changes whenever focus moves
--- to another window or application: its application's process id and its
--- window id. Not part of the WindowInfo port: a caller compares two readings to
--- know the user is still in the window an asynchronous answer was meant for.
--- @return string|nil identity "<pid>:<window id>", or nil when unreadable.
function M.focused_identity()
	local ok, result = pcall(function()
		local win = hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
		if not win then return nil end
		local window_id = win:id()
		local app = win:application()
		local pid = app and app:pid()
		if window_id == nil or pid == nil then return nil end
		return tostring(pid) .. ":" .. tostring(window_id)
	end)
	if not ok then
		Logger.error(LOG, "focused_identity(): unexpected error — %s", tostring(result))
		return nil
	end
	return result
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
