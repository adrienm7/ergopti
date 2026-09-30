--- adapters/window_manager.lua

--- ==============================================================================
--- MODULE: WindowManager Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the WindowManager port contract defined in
--- static/ergopti_plus/_shared/core/ports/WindowManager.spec.js. Wraps hs.window and
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
local Logger = require("infra.logger")

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
				return app:activate() == true
			end
			return false
		end
		-- Treat as an hs.window object or integer ID
		local win = type(hwnd_or_spec) == "userdata" and hwnd_or_spec
			or (hs.window and hs.window.get and hs.window.get(hwnd_or_spec))
		if win then
			-- hs.window:focus() returns the window object for chaining, not a
			-- boolean. Reject nil/false without requiring literal true.
			local focused = win:focus()
			return focused ~= nil and focused ~= false
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





-- ============================================
-- ============================================
-- ======= 2/ Direct application switch =======
-- ============================================
-- ============================================

-- Not part of the WindowManager port: the reads and the focus call that
-- modules/gestures/app_switch.lua needs to switch applications and windows
-- directly. A synthetic Cmd+Tab never did that: the Dock only commits its
-- switcher when Command itself is released, which a posted Tab keystroke
-- carrying the Command flag does not do.

--- Reads one on-screen window into a plain record. A window that closes while
--- it is read throws on its next accessibility call; that window alone is
--- skipped, as the Windows twin skips it (window_utils.ahk _AltTabCycle).
--- @param win userdata hs.window object.
--- @return table|nil record { window, id, pid, screen_id, standard, minimized }.
local function window_record(win)
	local ok, record = pcall(function()
		local app = win:application()
		local screen = win:screen()
		return {
			window    = win,
			id        = win:id(),
			pid       = app and app:pid() or nil,
			screen_id = screen and screen:id() or nil,
			standard  = win:isStandard() == true,
			minimized = win:isMinimized() == true,
		}
	end)
	if not ok then
		Logger.debug(LOG, "ordered_windows(): skipped a window that could not be read: %s", tostring(record))
		return nil
	end
	return record
end

--- Lists the on-screen windows of the current Space, front to back. Hidden
--- applications and minimised windows are not on screen, so they never lead.
--- @return table records Array of window records, most recently used first.
function M.ordered_windows()
	local ok, result = pcall(function()
		local records = {}
		for _, win in ipairs(hs.window.orderedWindows() or {}) do
			local record = window_record(win)
			if record then records[#records + 1] = record end
		end
		return records
	end)
	if not ok then
		Logger.error(LOG, "ordered_windows(): error — %s", tostring(result))
		return {}
	end
	return result
end

--- Lists every window of one application, including minimised ones.
--- @param pid number Process id of the application.
--- @return table records Array of window records, in the application's order.
function M.application_windows(pid)
	if type(pid) ~= "number" then error("application_windows: pid must be a number", 2) end
	local ok, result = pcall(function()
		local records = {}
		local app = hs.application.applicationForPID(pid)
		if not app then return records end
		for _, win in ipairs(app:allWindows() or {}) do
			local record = window_record(win)
			if record then records[#records + 1] = record end
		end
		return records
	end)
	if not ok then
		Logger.error(LOG, "application_windows(): error — %s", tostring(result))
		return {}
	end
	return result
end

--- @return number|nil id The id of the focused window, nil when none has focus.
function M.focused_window_id()
	local ok, result = pcall(function()
		local win = hs.window.focusedWindow()
		return win and win:id() or nil
	end)
	if not ok then
		Logger.error(LOG, "focused_window_id(): error — %s", tostring(result))
		return nil
	end
	return result
end

--- @return number|nil pid Process id of the frontmost application.
function M.frontmost_pid()
	local ok, result = pcall(function()
		local app = hs.application.frontmostApplication()
		return app and app:pid() or nil
	end)
	if not ok then
		Logger.error(LOG, "frontmost_pid(): error — %s", tostring(result))
		return nil
	end
	return result
end

--- @return number pid Process id of this runtime, which is never a switch target.
function M.own_pid()
	return hs.processInfo.processID
end

--- Focuses the window of a record and activates its application.
--- @param record table A record returned by ordered_windows or application_windows.
--- @return boolean focused
function M.focus_window(record)
	local ok, result = pcall(function()
		if record.minimized then record.window:unminimize() end
		-- hs.window:focus() returns the window for chaining, not a boolean.
		return record.window:focus()
	end)
	if not ok then
		Logger.warn(LOG, "focus_window(): window %s refused focus — %s", tostring(record.id), tostring(result))
		return false
	end
	return result ~= nil and result ~= false
end

return M
