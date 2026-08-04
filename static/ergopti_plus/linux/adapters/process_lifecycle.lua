--- adapters/process_lifecycle.lua

--- ==============================================================================
--- MODULE: ProcessLifecycle Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the ProcessLifecycle port contract defined in
--- static/ergopti_plus/_shared/core/ports/ProcessLifecycle.spec.js. Wraps a polling
--- loop backed by xdotool to detect focused-window changes, and a background
--- shell process monitoring loop for app launch/quit events.
---
--- FEATURES & RATIONALE:
--- 1. Polling model: Linux lacks a universal app-launch event API comparable to
---    hs.application.watcher; we poll xdotool getactivewindow at a 250 ms
---    interval and diff against the last known state to emit focus-change events.
--- 2. pgrep-based launch/quit: a background coroutine snapshots the running
---    process list every 2 s and fires registered callbacks on appearance or
---    disappearance. This is coarse but requires no root privilege or D-Bus setup.
--- 3. Idempotent start/stop: calling start() or stop() multiple times is safe.
--- 4. Callback lists: multiple consumers can register for the same event; the
---    adapter fans out to all registered handlers.
---
--- NOTE: The polling approach has a minimum latency of 250 ms for focus events
--- and 2 s for launch/quit events. A future contributor can swap the backend to
--- an AT-SPI2/D-Bus watcher for sub-100 ms latency without touching domain modules.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
-- The focused-window question belongs to one adapter. This file used to answer
-- it a second time, with its own xdotool calls, and it was the copy that fed the
-- keystroke path — so teaching WindowInfo about Wayland would have changed
-- nothing a user experiences.
local WindowInfo = require("adapters.window_info")

local LOG = "adapters.process_lifecycle"


-- Focus poll interval and process-list poll interval (in seconds)
local FOCUS_POLL_S   = 0.25
local PROCESS_POLL_S = 2.0




-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

local _focus_callbacks  = {}
local _launch_callbacks = {}
local _quit_callbacks   = {}
local _running          = false
local _last_focus_key   = nil
local _last_processes   = {}   -- set: process_name -> true

-- Timer handles (LuaJIT/luaposix compatible; we use a simple background thread
-- via coroutine + os.time for portability across LuaJIT versions)
local _focus_thread   = nil
local _process_thread = nil




-- =========================================
-- =========================================
-- ======= 2/ Internal Polling =============
-- =========================================
-- =========================================

-- Joins the application identity and the window title into one comparable key.
-- A control character rather than a printable one: a window title may legally
-- contain any punctuation, and a separator that can occur in the data makes two
-- different focus states compare equal.
local FOCUS_KEY_SEPARATOR = "\1"

--- Returns { appId, windowTitle } for the focused window, both "" when unknown.
---
--- Delegates rather than asking X11 itself. This file used to carry a second,
--- independent xdotool implementation — and it was the one that fed the
--- keystroke path's application cache, so the WindowInfo adapter could have been
--- made to speak every Wayland compositor without changing anything a user sees.
--- One question, one answer, wherever the answer has to come from.
--- @return string appId, string windowTitle
local function _focused_identity()
	local ok, info = pcall(WindowInfo.getFocused)
	if not ok or type(info) ~= "table" then return "", "" end
	return info.appId or "", info.windowTitle or ""
end

--- A value that changes exactly when the focused window's identity changes.
---
--- Includes the TITLE, not just the application. A browser switching to a
--- private window keeps its process and its window, and that transition is the
--- one the password-suppression feature exists to notice — keying on the window
--- id, as this did, made it structurally invisible.
--- @param app_id string
--- @param title string
--- @return string
local function _focus_key(app_id, title)
	return app_id .. FOCUS_KEY_SEPARATOR .. title
end

--- Returns a set (name -> true) of currently running process names via ps.
local function _snapshot_processes()
	local fh = io.popen("ps -eo comm 2>/dev/null", "r")
	if not fh then return {} end
	local snapshot = {}
	for line in fh:lines() do
		local name = line:match("^%s*(.-)%s*$")
		if name and name ~= "" and name ~= "COMMAND" then
			snapshot[name] = true
		end
	end
	fh:close()
	return snapshot
end




-- =========================================
-- =========================================
-- ======= 3/ Adapter Methods ==============
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
		local app_name, title = _focused_identity()
		return { appId = app_name, windowTitle = title }
	end)
	if not ok then
		Logger.error(LOG, "getForegroundApp(): unexpected error — %s", tostring(result))
		return empty
	end
	return result or empty
end

--- Starts the focus and process-list polling loops.
--- Idempotent: has no effect when the loops are already running.
function M.start()
	if _running then return end
	_running = true
	_last_focus_key = _focus_key(_focused_identity())
	_last_processes = _snapshot_processes()

	-- Focus polling loop: runs as a background coroutine ticked by the caller.
	-- For environments without an event loop, we spawn a shell background poll
	-- via a detached sub-process that writes to a named pipe — simpler and more
	-- portable than embedding a LuaJIT thread. The coroutine approach is kept
	-- as a comment for future native implementations.
	--
	-- Current implementation: the daemon's main loop must call M.tick() at
	-- FOCUS_POLL_S intervals to drive focus-change detection.
	Logger.debug(LOG, "start(): polling adapters started (call M.tick() at %.2f s).",
		FOCUS_POLL_S)
end

--- Stops the polling loops and releases resources.
--- Idempotent: has no effect when already stopped.
function M.stop()
	if not _running then return end
	_running = false
	_last_focus_key = nil
	_last_processes = {}
	Logger.debug(LOG, "stop(): polling adapters stopped.")
end

--- Drives the focus-change and process-list detection. Must be called periodically
--- by the host event loop (typically at FOCUS_POLL_S intervals for focus,
--- and every PROCESS_POLL_S / FOCUS_POLL_S ticks for process detection).
--- @param tick_count number Monotonically incrementing tick counter (used to throttle process polling).
function M.tick(tick_count)
	if not _running then return end
	tick_count = tonumber(tick_count) or 0

	-- Focus-change check (every tick)
	local ok_f = pcall(function()
		local app_name, title = _focused_identity()
		local key = _focus_key(app_name, title)
		if key ~= _last_focus_key then
			_last_focus_key = key
			for _, cb in ipairs(_focus_callbacks) do
				pcall(cb, app_name, title)
			end
		end
	end)
	if not ok_f then
		Logger.debug(LOG, "tick(): focus poll error — suppressed.")
	end

	-- Process-list check (every N ticks to stay within PROCESS_POLL_S)
	local process_every = math.max(1, math.floor(PROCESS_POLL_S / FOCUS_POLL_S))
	if tick_count % process_every == 0 then
		local ok_p = pcall(function()
			local current = _snapshot_processes()
			-- Launched: in current but not in last
			for name in pairs(current) do
				if not _last_processes[name] then
					for _, cb in ipairs(_launch_callbacks) do pcall(cb, name) end
				end
			end
			-- Quit: in last but not in current
			for name in pairs(_last_processes) do
				if not current[name] then
					for _, cb in ipairs(_quit_callbacks) do pcall(cb, name) end
				end
			end
			_last_processes = current
		end)
		if not ok_p then
			Logger.debug(LOG, "tick(): process poll error — suppressed.")
		end
	end
end

return M
