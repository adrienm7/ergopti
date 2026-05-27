--- adapters/process_lifecycle.lua

--- ==============================================================================
--- MODULE: ProcessLifecycle Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the ProcessLifecycle port contract. Wraps
--- hs.application.watcher and hs.window.filter to expose app-launch, app-quit,
--- and window-focus-change events to domain modules without coupling them to hs
--- APIs.
---
--- FEATURES & RATIONALE:
--- 1. Idempotent start/stop: calling start() or stop() multiple times is safe;
---    a guard flag prevents duplicate watcher creation or double-stop crashes.
--- 2. Defensive pcall: watcher setup and event dispatch are wrapped in pcall so
---    a misbehaving callback never crashes the watcher loop.
--- 3. Callback lists: multiple consumers can register for the same event without
---    knowledge of each other; the adapter fans out to all registered handlers.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.process_lifecycle"




-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

local _focus_callbacks  = {}   -- list of focus-change callbacks
local _launch_callbacks = {}   -- list of app-launch callbacks
local _quit_callbacks   = {}   -- list of app-quit callbacks
local _app_watcher      = nil  -- hs.application.watcher instance
local _window_filter    = nil  -- hs.window.filter instance (focus changes)
local _running          = false




-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Registers a callback to be fired whenever the focused window changes.
--- @param callback function Called with (appName: string, windowTitle: string).
function M.onFocusChange(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onFocusChange(): argument is not a function — ignored.")
		return
	end
	_focus_callbacks[#_focus_callbacks + 1] = callback
end

--- Registers a callback to be fired whenever an application is launched.
--- @param callback function Called with (appName: string).
function M.onAppLaunch(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onAppLaunch(): argument is not a function — ignored.")
		return
	end
	_launch_callbacks[#_launch_callbacks + 1] = callback
end

--- Registers a callback to be fired whenever an application terminates.
--- @param callback function Called with (appName: string).
function M.onAppQuit(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onAppQuit(): argument is not a function — ignored.")
		return
	end
	_quit_callbacks[#_quit_callbacks + 1] = callback
end

--- Returns identity information about the currently focused application window.
--- @return table { appId: string, windowTitle: string } — fields are "" on error.
function M.getForegroundApp()
	local empty = { appId = "", windowTitle = "" }
	local ok, result = pcall(function()
		local win = hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
		if not win then return empty end
		local app_name    = ""
		local win_title   = ""
		local ok_title, t = pcall(function() return win:title() end)
		if ok_title and type(t) == "string" then win_title = t end
		local ok_app, app = pcall(function() return win:application() end)
		if ok_app and app then
			local ok_name, n = pcall(function() return app:name() end)
			if ok_name and type(n) == "string" then app_name = n end
		end
		return { appId = app_name, windowTitle = win_title }
	end)
	if not ok then
		Logger.error(LOG, "getForegroundApp(): unexpected error — %s", tostring(result))
		return empty
	end
	return result or empty
end

--- Starts the application and window-focus watchers.
--- Idempotent: has no effect when the watchers are already running.
function M.start()
	if _running then return end

	-- Application watcher — launch and quit events
	pcall(function()
		_app_watcher = hs.application.watcher.new(function(app_name, event_type, _app_obj)
			if event_type == hs.application.watcher.launched then
				for _, cb in ipairs(_launch_callbacks) do
					pcall(cb, app_name)
				end
			elseif event_type == hs.application.watcher.terminated then
				for _, cb in ipairs(_quit_callbacks) do
					pcall(cb, app_name)
				end
			end
		end)
		_app_watcher:start()
	end)

	-- Window filter — focus-change events
	pcall(function()
		_window_filter = hs.window.filter.new()
		_window_filter:subscribe(hs.window.filter.windowFocused, function(win)
			local app_name  = ""
			local win_title = ""
			local ok_app, app = pcall(function() return win:application() end)
			if ok_app and app then
				local ok_name, n = pcall(function() return app:name() end)
				if ok_name and type(n) == "string" then app_name = n end
			end
			local ok_title, t = pcall(function() return win:title() end)
			if ok_title and type(t) == "string" then win_title = t end
			for _, cb in ipairs(_focus_callbacks) do
				pcall(cb, app_name, win_title)
			end
		end)
	end)

	_running = true
	Logger.debug(LOG, "start(): watchers started.")
end

--- Stops the application and window-focus watchers and releases their resources.
--- Idempotent: has no effect when the watchers are already stopped.
function M.stop()
	if not _running then return end

	pcall(function()
		if _app_watcher then
			_app_watcher:stop()
			_app_watcher = nil
		end
	end)

	pcall(function()
		if _window_filter then
			_window_filter:unsubscribeAll()
			_window_filter = nil
		end
	end)

	_running = false
	Logger.debug(LOG, "stop(): watchers stopped.")
end

return M
