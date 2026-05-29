--- linux/adapters/window_manager.lua

--- ==============================================================================
--- MODULE: WindowManager Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the WindowManager port contract defined in
--- static/ergopti_plus/shared/ports/WindowManager.spec.js. Wraps xdotool and
--- wmctrl to activate, query, and manage windows without coupling domain
--- modules to compositor-specific APIs.
---
--- FEATURES & RATIONALE:
--- 1. xdotool for activation and title lookup: xdotool windowactivate/getwindowname
---    works on X11 and through XWayland on most Wayland compositors.
--- 2. wmctrl for kill: wmctrl -c sends WM_DELETE_WINDOW; xdotool windowkill is
---    the hard fallback for windows that ignore the close request.
--- 3. Return-false on error: activate(), exists(), and kill() return false on
---    any failure so callers can branch without catching exceptions.
--- 4. Return-empty-object: getFocused() always returns a table with all fields
---    populated (hwnd=0 and strings="" when unavailable).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.window_manager"

local INVALID_HWND = 0




-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Reads a line from a shell command.
--- @param cmd string
--- @return string|nil
local function _popen_line(cmd)
	local fh = io.popen(cmd .. " 2>/dev/null", "r")
	if not fh then return nil end
	local line = fh:read("*l")
	fh:close()
	return line
end

--- Returns the xdotool window ID for the first window whose name matches spec.
--- @param spec string App name or window title substring.
--- @return number|nil
local function _find_window_by_spec(spec)
	-- Try by process name first (xdotool search --classname / --name)
	local id_str = _popen_line(
		string.format("xdotool search --classname %q | head -1", spec))
	local id = tonumber(id_str)
	if id then return id end
	id_str = _popen_line(
		string.format("xdotool search --name %q | head -1", spec))
	return tonumber(id_str)
end




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Brings a window to the foreground and gives it focus.
--- @param hwnd_or_spec any xdotool window ID (number) or app/title name (string).
--- @return boolean true on success, false otherwise.
function M.activate(hwnd_or_spec)
	local ok, result = pcall(function()
		local wid
		if type(hwnd_or_spec) == "number" and hwnd_or_spec ~= INVALID_HWND then
			wid = hwnd_or_spec
		elseif type(hwnd_or_spec) == "string" then
			wid = _find_window_by_spec(hwnd_or_spec)
		end
		if not wid then return false end
		local code = os.execute(
			string.format("xdotool windowactivate --sync %d 2>/dev/null", wid))
		return code == true or code == 0
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
		local wid = _find_window_by_spec(spec)
		return wid ~= nil
	end)
	if not ok then
		Logger.error(LOG, "exists(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Sends a close request to all windows matching the spec.
--- Uses wmctrl -c (graceful) with xdotool windowkill fallback (hard).
--- @param spec string App name to close.
--- @return boolean true if the kill was issued, false on any error.
function M.kill(spec)
	local ok, result = pcall(function()
		if type(spec) ~= "string" then return false end
		-- Graceful close via wmctrl
		local code = os.execute(
			string.format("wmctrl -c %q 2>/dev/null", spec))
		if code == true or code == 0 then return true end
		-- Hard fallback via xdotool
		local wid = _find_window_by_spec(spec)
		if not wid then return false end
		code = os.execute(
			string.format("xdotool windowkill %d 2>/dev/null", wid))
		return code == true or code == 0
	end)
	if not ok then
		Logger.error(LOG, "kill(): error — %s", tostring(result))
		return false
	end
	return result == true
end

--- Returns an array of window IDs for all currently visible windows.
--- @return table Array of xdotool window ID integers (may be empty).
function M.getList()
	local ok, result = pcall(function()
		local fh = io.popen("xdotool search --onlyvisible --name '' 2>/dev/null", "r")
		if not fh then return {} end
		local ids = {}
		for line in fh:lines() do
			local id = tonumber(line)
			if id then ids[#ids + 1] = id end
		end
		fh:close()
		return ids
	end)
	if not ok then
		Logger.error(LOG, "getList(): error — %s", tostring(result))
		return {}
	end
	return type(result) == "table" and result or {}
end

--- Returns the title bar text of a window.
--- @param hwnd_or_spec any xdotool window ID (number) or app name (string).
--- @return string Window title, or "" if not found.
function M.getTitle(hwnd_or_spec)
	local ok, result = pcall(function()
		local wid
		if type(hwnd_or_spec) == "number" and hwnd_or_spec ~= INVALID_HWND then
			wid = hwnd_or_spec
		elseif type(hwnd_or_spec) == "string" then
			wid = _find_window_by_spec(hwnd_or_spec)
		end
		if not wid then return "" end
		local title = _popen_line(
			string.format("xdotool getwindowname %d", wid))
		return type(title) == "string" and title or ""
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
		local id_str = _popen_line("xdotool getactivewindow")
		local wid = tonumber(id_str)
		if not wid then return empty end

		local title = _popen_line(
			string.format("xdotool getwindowname %d", wid)) or ""

		-- WM_CLASS: "instance", "ClassName" — use second field as process name
		local cls_out = _popen_line(
			string.format("xprop -id %d WM_CLASS", wid)) or ""
		local process = cls_out:match('"[^"]+"%s*,%s*"([^"]+)"') or
		                cls_out:match('"([^"]+)"') or ""

		return { hwnd = wid, title = title, process = process }
	end)
	if not ok then
		Logger.error(LOG, "getFocused(): error — %s", tostring(result))
		return empty
	end
	return type(result) == "table" and result or empty
end

return M
