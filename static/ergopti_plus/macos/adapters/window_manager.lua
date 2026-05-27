--- adapters/window_manager.lua

--- ==============================================================================
--- MODULE: WindowManager Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the WindowManager port contract defined in
--- static/ergopti_plus/shared/ports/WindowManager.spec.js. Wraps hs.window and
--- hs.application to activate, query, and manage windows without coupling
--- domain modules to hs-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. Return-false on error: activate(), exists(), and kill() return false on
---    any failure so callers can branch without catching exceptions.
--- 2. Return-empty-object: getFocused() always returns a table with all fields
---    populated (hwnd=0 and strings="" when unavailable).
--- 3. Defensive pcall: all hs.window calls are wrapped to prevent propagation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.window_manager"

-- Sentinel HWND used when no real handle is available (matches AHK convention).
local INVALID_HWND = 0




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Brings a window to the foreground and gives it focus.
--- @param hwnd_or_spec any hs.window object, window ID, or app name string.
--- @return boolean true on success, false otherwise.
function M.activate(hwnd_or_spec)
	local ok, result = pcall(function()
		if type(hwnd_or_spec) == "string" then
			local app = hs.application.get(hwnd_or_spec)
			if app then
				app:activate()
				return true
			end
			return false
		end
		-- Treat as an hs.window object or integer ID
		local win = type(hwnd_or_spec) == "userdata" and hwnd_or_spec
			or (hs.window and hs.window.get and hs.window.get(hwnd_or_spec))
		if win then
			win:focus()
			return true
		end
		return false
	end)
	if not ok then
		Logger.error(LOG, "activate(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Checks whether at least one window matching the spec exists.
--- @param spec string App name or window title fragment.
--- @return boolean
function M.exists(spec)
	local ok, result = pcall(function()
		if type(spec) ~= "string" then return false end
		local app = hs.application.get(spec)
		if app then return true end
		local wins = hs.window and hs.window.allWindows and hs.window.allWindows() or {}
		for _, w in ipairs(wins) do
			local ok_t, title = pcall(function() return w:title() end)
			if ok_t and type(title) == "string" and title:find(spec, 1, true) then
				return true
			end
		end
		return false
	end)
	if not ok then
		Logger.error(LOG, "exists(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Forcefully terminates all windows matching the spec.
--- @param spec string App name to terminate.
--- @return boolean true if the kill was issued, false on any error.
function M.kill(spec)
	local ok, result = pcall(function()
		if type(spec) ~= "string" then return false end
		local app = hs.application.get(spec)
		if not app then return false end
		app:kill()
		return true
	end)
	if not ok then
		Logger.error(LOG, "kill(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Returns an array of window IDs for all currently visible windows.
--- @return table Array of window ID integers (may be empty).
function M.getList()
	local ok, result = pcall(function()
		local wins = hs.window and hs.window.allWindows and hs.window.allWindows() or {}
		local ids = {}
		for _, w in ipairs(wins) do
			local ok_id, id = pcall(function() return w:id() end)
			if ok_id and id then
				ids[#ids + 1] = id
			end
		end
		return ids
	end)
	if not ok then
		Logger.error(LOG, "getList(): error — %s", tostring(result))
		return {}
	end
	return type(result) == "table" and result or {}
end

--- Returns the title bar text of a window.
--- @param hwnd_or_spec any hs.window object, window ID, or app name string.
--- @return string Window title, or "" if not found.
function M.getTitle(hwnd_or_spec)
	local ok, result = pcall(function()
		if type(hwnd_or_spec) == "string" then
			local app = hs.application.get(hwnd_or_spec)
			if app then
				local win = app:mainWindow()
				if win then
					local ok_t, title = pcall(function() return win:title() end)
					return (ok_t and type(title) == "string") and title or ""
				end
			end
			return ""
		end
		local win = type(hwnd_or_spec) == "userdata" and hwnd_or_spec
			or (hs.window and hs.window.get and hs.window.get(hwnd_or_spec))
		if not win then return "" end
		local ok_t, title = pcall(function() return win:title() end)
		return (ok_t and type(title) == "string") and title or ""
	end)
	if not ok then
		Logger.error(LOG, "getTitle(): error — %s", tostring(result))
		return ""
	end
	return type(result) == "string" and result or ""
end

--- Returns the identity of the currently focused window.
--- @return table { hwnd: number, title: string, process: string }
function M.getFocused()
	local empty = { hwnd = INVALID_HWND, title = "", process = "" }
	local ok, result = pcall(function()
		local win = hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
		if not win then return empty end

		local ok_id, id = pcall(function() return win:id() end)
		local ok_t, title = pcall(function() return win:title() end)
		local process = ""
		local ok_app, app = pcall(function() return win:application() end)
		if ok_app and app then
			local ok_name, name = pcall(function() return app:name() end)
			if ok_name and type(name) == "string" then process = name end
		end

		return {
			hwnd    = (ok_id and type(id) == "number") and id or INVALID_HWND,
			title   = (ok_t and type(title) == "string") and title or "",
			process = process,
		}
	end)
	if not ok then
		Logger.error(LOG, "getFocused(): error — %s", tostring(result))
		return empty
	end
	return type(result) == "table" and result or empty
end

return M
