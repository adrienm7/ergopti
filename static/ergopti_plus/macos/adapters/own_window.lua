--- adapters/own_window.lua

--- ==============================================================================
--- MODULE: Own Window Lookup Adapter (Hammerspoon)
--- DESCRIPTION:
--- Resolves the hs.window of a webview or of the console among this process's
--- own windows, without ever enumerating the windows of other applications.
---
--- FEATURES & RATIONALE:
--- 1. No global scan: webview:hswindow() and hs.console.hswindow() push the
---    native window number and call hs.window.windowForID, an alias of
---    hs.window.get, i.e. find(id, true) over hs.window.allWindows(): every
---    window of every running application read through Accessibility on the
---    main thread. Opening any webview froze Hammerspoon 2.8 s to 3.2 s that
---    way on macOS 26 (issue #100), and the focus retry repeated the scan up to
---    twenty times while a new window was still being composited.
--- 2. Exact identity: the native call is made with windowForID replaced, for
---    that synchronous call only, by a recorder of the window number it
---    receives. The window carrying that number is then picked among the
---    windows of this process, found by PID. Titles are never compared: two
---    windows may share one.
--- 3. Not yet available reads as nil: a window number of zero or less (the
---    window has no window device yet) or a number Accessibility does not list
---    yet. Callers own the bounded retry; a native failure or a missing own
---    process raises.
--- 4. Late binding: the global `hs` is read at call time, so a test double
---    installed after this module loaded is the one consulted. A double whose
---    hswindow() answers without going through windowForID is returned as is:
---    that path performs no lookup to intercept.
--- ==============================================================================

local M = {}

local RunningApplication = require("adapters.running_application")

-- True while a native hswindow() call runs with windowForID recorded.
local _capturing = false





-- =====================================
-- =====================================
-- ======= 1/ Window Number Read =======
-- =====================================
-- =====================================

--- Runs a native hswindow() call with hs.window.windowForID recorded instead
--- of performed.
--- @param resolve function Calls the native hswindow() and returns its result.
--- @return number|nil window_number Number the native call asked for, or nil.
--- @return any direct Result of a call that never asked hs.window.
local function read_window_number(resolve)
	if _capturing then error("own_window: re-entrant window number read", 2) end
	local native = rawget(_G, "hs")
	local window_module = type(native) == "table" and native.window or nil
	if type(window_module) ~= "table" then return nil, resolve() end
	local original = rawget(window_module, "windowForID")
	local asked, number = false, nil
	window_module.windowForID = function(window_number)
		asked, number = true, window_number
		return nil
	end
	_capturing = true
	local ok, result = pcall(resolve)
	_capturing = false
	window_module.windowForID = original
	if not ok then error(result, 0) end
	if not asked then return nil, result end
	if type(number) ~= "number" then
		error("own_window: hswindow() passed a non-numeric window number", 2)
	end
	return number, nil
end

--- Returns this process's window carrying `window_number`.
--- @param window_number number Native window number.
--- @return userdata|table|nil window The hs.window, or nil when not listed yet.
local function own_window_by_number(window_number)
	if window_number <= 0 then return nil end
	local app = RunningApplication.current()
	if app == nil then error("own_window: the running Hammerspoon process is unavailable", 0) end
	for _, window in ipairs(app:allWindows() or {}) do
		if window:id() == window_number then return window end
	end
	return nil
end





-- =================================
-- =================================
-- ======= 2/ Public Lookups =======
-- =================================
-- =================================

--- Returns the native window number of a webview without any window lookup.
--- @param view userdata|table The hs.webview object.
--- @return number|nil window_number The number, or nil when it has none yet.
function M.webview_window_number(view)
	local number = read_window_number(function() return view:hswindow() end)
	if number == nil or number <= 0 then return nil end
	return number
end

--- Returns the hs.window of a webview, found among this process's windows.
--- @param view userdata|table The hs.webview object.
--- @return userdata|table|nil window The window, or nil when not available yet.
function M.for_webview(view)
	local number, direct = read_window_number(function() return view:hswindow() end)
	if number == nil then return direct end
	return own_window_by_number(number)
end

--- Returns the hs.window of the Hammerspoon console, among this process's windows.
--- @return userdata|table|nil window The window, or nil when not available yet.
function M.console()
	local number, direct = read_window_number(function() return hs.console.hswindow() end)
	if number == nil then return direct end
	return own_window_by_number(number)
end

--- True when the webview's window is the focused window. Only the focused
--- window is read; no window list is.
--- @param view userdata|table The hs.webview object.
--- @return boolean focused
function M.is_webview_focused(view)
	local number, direct = read_window_number(function() return view:hswindow() end)
	if number == nil then
		if direct == nil then return false end
		number = direct:id()
	end
	if type(number) ~= "number" or number <= 0 then return false end
	local focused = hs.window.focusedWindow()
	return focused ~= nil and focused:id() == number
end

return M
