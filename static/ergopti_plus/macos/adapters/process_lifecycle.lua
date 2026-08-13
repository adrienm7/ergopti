--- adapters/process_lifecycle.lua

--- ==============================================================================
--- MODULE: ProcessLifecycle Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the ProcessLifecycle port contract. Owns the
--- application watcher and optional window filter transactionally, and fans out
--- their events without allowing one subscriber exception to disappear or stop
--- healthy sibling subscribers.
---
--- FEATURES & RATIONALE:
--- 1. Transactional start: native handles are published as active only after the
---    corresponding start or subscription operation succeeds.
--- 2. Retryable stop: a failed native teardown retains the exact handle while
---    generation guards make callbacks from that ambiguous handle inert.
--- 3. Visible callback isolation: subscribers run under xpcall with traceback and
---    every exception reaches the central file logger.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.process_lifecycle"





-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

local _focus_callbacks    = {}
local _launch_callbacks   = {}
local _quit_callbacks     = {}
local _activate_callbacks = {}

local _app_watcher          = nil
local _window_filter        = nil
local _app_watcher_active   = false
local _window_filter_active = false
local _app_cleanup_pending  = false
local _window_cleanup_pending = false
local _running             = false
local _app_generation      = 0
local _window_generation   = 0

--- Invokes one subscriber without hiding its exception from the file logger.
--- @param callback function Subscriber to invoke.
--- @param callback_class string Human-readable callback class for diagnostics.
--- @param ... any Arguments forwarded to the subscriber.
--- @return boolean True when the subscriber completed normally.
local function invoke_callback(callback, callback_class, ...)
	local args = table.pack(...)
	local ok, err = xpcall(function()
		return callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s subscriber raised: %s.", callback_class, tostring(err))
	end
	return ok
end

--- Retries teardown of the exact application-watcher handle currently owned.
--- @return boolean True only when no application-watcher cleanup debt remains.
local function cleanup_app_watcher()
	if not _app_watcher then
		_app_cleanup_pending = false
		return true
	end
	local watcher = _app_watcher
	local ok, result = xpcall(function() return watcher:stop() end, debug.traceback)
	if not ok or not result then
		_app_cleanup_pending = true
		Logger.error(LOG, "Application watcher stop failed; retaining the exact handle for retry: %s.",
			tostring(result))
		return false
	end
	if _app_watcher == watcher then _app_watcher = nil end
	_app_cleanup_pending = false
	return true
end

--- Retries teardown of the exact window-filter handle currently owned.
--- @return boolean True only when no window-filter cleanup debt remains.
local function cleanup_window_filter()
	if not _window_filter then
		_window_cleanup_pending = false
		return true
	end
	local filter = _window_filter
	local ok, result = xpcall(function() return filter:unsubscribeAll() end, debug.traceback)
	if not ok or not result then
		_window_cleanup_pending = true
		Logger.error(LOG, "Window filter stop failed; retaining the exact handle for retry: %s.",
			tostring(result))
		return false
	end
	if _window_filter == filter then _window_filter = nil end
	_window_cleanup_pending = false
	return true
end

--- Rolls back only the native handles acquired by the current start attempt.
--- Existing active siblings are preserved; newly acquired handles are first made
--- callback-inert, then synchronously released or retained as cleanup debt.
--- @param app_acquired boolean Whether this attempt acquired the app watcher.
--- @param window_acquired boolean Whether this attempt acquired the window filter.
--- @return boolean True only when every rollback teardown completed.
local function rollback_start(app_acquired, window_acquired)
	_running = false
	if app_acquired then
		_app_watcher_active = false
		_app_generation = _app_generation + 1
		_app_cleanup_pending = _app_watcher ~= nil
	end
	if window_acquired then
		_window_filter_active = false
		_window_generation = _window_generation + 1
		_window_cleanup_pending = _window_filter ~= nil
	end

	-- Attempt both releases even when the first fails: otherwise one cleanup
	-- exception turns a failed transaction into two independently live orphans.
	local app_clean = not app_acquired or cleanup_app_watcher()
	local window_clean = not window_acquired or cleanup_window_filter()
	return app_clean and window_clean
end





-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Registers a callback to be fired whenever the focused window changes.
--- @param callback function Called with an application name and window title.
function M.onFocusChange(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onFocusChange(): argument is not a function — ignored.")
		return
	end
	_focus_callbacks[#_focus_callbacks + 1] = callback
end

--- Registers a callback to be fired whenever an application is launched.
--- @param callback function Called with the application name.
function M.onAppLaunch(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onAppLaunch(): argument is not a function — ignored.")
		return
	end
	_launch_callbacks[#_launch_callbacks + 1] = callback
end

--- Registers a callback to be fired whenever an application terminates.
--- @param callback function Called with the application name.
function M.onAppQuit(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onAppQuit(): argument is not a function — ignored.")
		return
	end
	_quit_callbacks[#_quit_callbacks + 1] = callback
end

--- Registers a callback for application activation with the native app object.
--- @param callback function Called with the application name and object.
function M.onAppActivate(callback)
	if type(callback) ~= "function" then
		Logger.warn(LOG, "onAppActivate(): argument is not a function — ignored.")
		return
	end
	_activate_callbacks[#_activate_callbacks + 1] = callback
end

--- Returns identity information about the currently focused application window.
--- @return table Identity fields, both empty strings on failure.
function M.getForegroundApp()
	local empty = { appId = "", windowTitle = "" }
	local ok, result = pcall(function()
		local win = hs.window and hs.window.focusedWindow and hs.window.focusedWindow()
		if not win then return empty end
		local app_name  = ""
		local win_title = ""
		local ok_title, title = pcall(function() return win:title() end)
		if ok_title and type(title) == "string" then win_title = title end
		local ok_app, app = pcall(function() return win:application() end)
		if ok_app and app then
			local ok_name, name = pcall(function() return app:name() end)
			if ok_name and type(name) == "string" then app_name = name end
		end
		return { appId = app_name, windowTitle = win_title }
	end)
	if not ok then
		Logger.error(LOG, "getForegroundApp(): unexpected error — %s", tostring(result))
		return empty
	end
	return result or empty
end

--- Starts every watcher required by the currently registered callback classes.
--- @return boolean True only when every required native capability is active.
function M.start()
	local focus_required = #_focus_callbacks > 0
	local app_acquired = false
	if _running and _app_watcher_active
		and (not focus_required or _window_filter_active) then return true end

	Logger.start(LOG, "Starting process lifecycle watchers…")
	if _app_cleanup_pending and not cleanup_app_watcher() then
		Logger.error(LOG, "start(): prior application-watcher cleanup is still pending.")
		return false
	end
	if _window_cleanup_pending and not cleanup_window_filter() then
		Logger.error(LOG, "start(): prior window-filter cleanup is still pending.")
		return false
	end

	if not _app_watcher_active then
		_app_generation = _app_generation + 1
		local watcher_generation = _app_generation
		local ok_new, candidate = xpcall(function()
			return hs.application.watcher.new(function(app_name, event_type, app_obj)
				if watcher_generation ~= _app_generation or not _app_watcher_active then return end
				if event_type == hs.application.watcher.launched then
					for _, callback in ipairs(_launch_callbacks) do
						invoke_callback(callback, "Application launch", app_name)
					end
				elseif event_type == hs.application.watcher.terminated then
					for _, callback in ipairs(_quit_callbacks) do
						invoke_callback(callback, "Application quit", app_name)
					end
				elseif event_type == hs.application.watcher.activated then
					for _, callback in ipairs(_activate_callbacks) do
						invoke_callback(callback, "Application activation", app_name, app_obj)
					end
				end
			end)
		end, debug.traceback)
		if not ok_new or not candidate then
			Logger.error(LOG, "Application watcher creation failed: %s.", tostring(candidate))
			return false
		end

		_app_watcher = candidate
		app_acquired = true
		local ok_start, start_result = xpcall(function() return candidate:start() end,
			debug.traceback)
		if not ok_start or not start_result then
			rollback_start(true, false)
			Logger.error(LOG, "Application watcher start failed: %s.", tostring(start_result))
			return false
		end
		_app_watcher_active = true
	end

	if focus_required and not _window_filter_active then
		_window_generation = _window_generation + 1
		local filter_generation = _window_generation
		local ok_new, candidate = xpcall(function() return hs.window.filter.new() end,
			debug.traceback)
		if not ok_new or not candidate then
			rollback_start(app_acquired, false)
			Logger.error(LOG, "Window filter creation failed: %s.", tostring(candidate))
			return false
		end

		-- Publish ownership before subscribe(): a native implementation may throw
		-- after partially registering the callback. Losing this candidate here
		-- would make the orphan impossible to unsubscribe or retry.
		_window_filter = candidate
		_window_cleanup_pending = true
		local ok_subscribe, subscribed = xpcall(function()
			return candidate:subscribe(hs.window.filter.windowFocused, function(win)
				if filter_generation ~= _window_generation or not _window_filter_active then return end
				local app_name  = ""
				local win_title = ""
				local ok_app, app = pcall(function() return win:application() end)
				if ok_app and app then
					local ok_name, name = pcall(function() return app:name() end)
					if ok_name and type(name) == "string" then app_name = name end
				end
				local ok_title, title = pcall(function() return win:title() end)
				if ok_title and type(title) == "string" then win_title = title end
				for _, callback in ipairs(_focus_callbacks) do
					invoke_callback(callback, "Window focus", app_name, win_title)
				end
			end)
		end, debug.traceback)
		if not ok_subscribe or not subscribed then
			rollback_start(app_acquired, true)
			Logger.error(LOG, "Window filter subscription failed: %s.", tostring(subscribed))
			return false
		end
		_window_cleanup_pending = false
		_window_filter_active = true
	end

	_running = _app_watcher_active and (not focus_required or _window_filter_active)
	if not _running then
		Logger.error(LOG, "start(): required watcher ownership was not committed.")
		return false
	end
	Logger.success(LOG, "Process lifecycle watchers started.")
	return true
end

--- Stops the native watchers while retaining any handle whose teardown fails.
--- @return boolean True only when every exact native handle was released.
function M.stop()
	if not _app_watcher and not _window_filter then return true end
	Logger.start(LOG, "Stopping process lifecycle watchers…")
	_running = false
	_app_watcher_active = false
	_window_filter_active = false
	_app_generation = _app_generation + 1
	_window_generation = _window_generation + 1
	_app_cleanup_pending = _app_watcher ~= nil
	_window_cleanup_pending = _window_filter ~= nil

	local app_stopped = cleanup_app_watcher()
	local window_stopped = cleanup_window_filter()
	if not app_stopped or not window_stopped then
		Logger.error(LOG, "stop(): native watcher cleanup remains pending.")
		return false
	end
	Logger.success(LOG, "Process lifecycle watchers stopped.")
	return true
end

return M
