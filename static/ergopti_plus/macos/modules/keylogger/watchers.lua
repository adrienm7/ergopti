--- modules/keylogger/watchers.lua

--- ==============================================================================
--- MODULE: Keylogger Hardware Watchers And Sensors
--- DESCRIPTION:
--- Owns the keylogger's background sensor layer: the once-per-second maintenance
--- and idle timers, the system sleep/wake/lock caffeinate callback, and the
--- Wi-Fi / battery / spaces / audio hardware watchers. Extracted from
--- keylogger/init.lua so the core event-tap engine stays focused on intercepting
--- keystrokes, while this module is the single owner of the sensor handles and
--- their throttle/day-rotation bookkeeping.
---
--- FEATURES & RATIONALE:
--- 1. Single owner of sensor handles — the four hardware watcher handles and the
---    audio-active flag live here only, so init.lua can never leave a dangling
---    watcher and teardown happens through one stop_hardware_watchers() path.
--- 2. Pause-aware throughout — every timer and watcher callback gates on the
---    injected _is_paused() predicate so no sensor event reaches the log while
---    the user has explicitly suspended the keylogger.
--- 3. Self-contained day rotation — _current_day and the system-load poll throttle
---    are private to this module, keeping the midnight-rotation invariant (flush
---    before rollover, never touching in-flight synth/enabled state) local.
--- ==============================================================================

local M = {}

local hs      = hs
local Logger  = require("infra.logger")
local Timings = require("infra.timings")
local TaskLifecycle = require("adapters.task_lifecycle")
local LOG     = "keylogger.watchers"

-- GC root for live hs.task objects. A task not referenced from a GC root can be
-- collected mid-run, which kills the subprocess so its completion callback never
-- fires. Canonical spelling recognised by tests/unit/meta/test_gc_retention.lua;
-- entries are released when the callback runs or the launch is refused.
local _active_tasks = {}


-- Timing thresholds come from the shared cross-driver registry
-- (_shared/modules/timings/constants.toml [keylogger]) so the AHK and macOS
-- keyloggers stay in sync; mirrored from keylogger/init.lua.
-- Typing session idle threshold before a "micro-idle" event is logged (30 s)
local MICRO_IDLE_TIMEOUT_MS      = Timings.ms("keylogger", "micro_idle_timeout_ms")
-- Typing session idle threshold before the session is considered fully ended (5 min)
local SESSION_TIMEOUT_MS         = Timings.ms("keylogger", "session_timeout_ms")
-- Minimum gap between system-load polls to avoid spawning top too often (5 min)
local SYSTEM_LOAD_POLL_INTERVAL_MS = Timings.ms("keylogger", "system_load_poll_ms")

-- Injected shared state and the pause predicate, both wired in M.init().
local _state     = nil
local _is_paused = nil

-- Log manager reference; the engine drains all sensor events through it.
local LogManager = require("modules.keylogger.log_manager")

-- Hardware watcher handles owned exclusively by this module
local _wifi_watcher         = nil
local _battery_watcher      = nil
local _spaces_watcher       = nil
local _audio_watcher_active = false

-- Day boundary tracker for the midnight rotation
local _current_day          = os.date("%Y-%m-%d")

-- Throttle for the expensive system-load poll
local _last_system_load_poll_ms = 0





-- ===========================================
-- ===========================================
-- ======= 1/ Guard And Initialization =======
-- ===========================================
-- ===========================================

--- Guards every public function against being called before M.init().
--- @param func_name string The calling function name for the error message.
--- @return boolean False if dependencies are not ready, true otherwise.
local function require_state(func_name)
	if not _state or not _is_paused then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end

--- Initializes the watcher layer with its two injected dependencies.
--- Must be called before any timer/watcher callback fires.
--- @param core_state table The shared state object from init.lua.
--- @param is_paused_fn function Predicate returning true while the script is paused.
function M.init(core_state, is_paused_fn)
	Logger.start(LOG, "Initializing keylogger watchers…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — watchers non-functional.")
		return
	end
	if type(is_paused_fn) ~= "function" then
		Logger.error(LOG, "M.init(): is_paused_fn must be a function — watchers non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state     = core_state
	_is_paused = is_paused_fn
	Logger.success(LOG, "Keylogger watchers initialized.")
end





-- ================================================
-- ================================================
-- ======= 2/ Hardware Watchers And Sensors =======
-- ================================================
-- ================================================

--- Polls mouse position and accumulates the physical travel distance.
--- Called every second via the maintenance timer.
local function poll_mouse_distance()
	local current_pos = hs.mouse.absolutePosition()
	if _state.last_mouse_pos then
		local dx   = current_pos.x - _state.last_mouse_pos.x
		local dy   = current_pos.y - _state.last_mouse_pos.y
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist > 0 then _state.mouse_distance_px = _state.mouse_distance_px + dist end
	end
	_state.last_mouse_pos = current_pos
end

--- Polls CPU usage via `top` and logs it as a system event.
--- Throttled to at most once per SYSTEM_LOAD_POLL_INTERVAL_MS to avoid spawning
--- a subprocess every 10 seconds.
local function poll_system_load()
	local now_ms = hs.timer.absoluteTime() / 1000000
	if (now_ms - _last_system_load_poll_ms) < SYSTEM_LOAD_POLL_INTERVAL_MS then return end
	_last_system_load_poll_ms = now_ms

	-- Declared before the closure so the callback can release its own pin
	-- (closure-before-local rule) rather than binding a nil global.
	local load_task
	load_task = TaskLifecycle.native("Keylogger system-load sample", "/usr/bin/top", function(_, stdout, _)
		if load_task then _active_tasks[load_task] = nil end
		Logger.pcall(LOG, function()
			stdout = type(stdout) == "string" and stdout or ""
			local cpu_user = stdout:match("CPU usage:%s*([%d%.]+)%%%s*user")
			local mem_used = stdout:match("PhysMem:%s*([%d%.A-Z]+)%s+used")
			LogManager.log_system_event("system_load", {
				cpu_user_percent = tonumber(cpu_user),
				mem_used         = mem_used,
			})
		end)
	end, { "-l", "1", "-n", "0" })
	if load_task then
		_active_tasks[load_task] = true
		if not TaskLifecycle.start(load_task, "Keylogger system-load sample") then
			_active_tasks[load_task] = nil
		end
	end
end

--- Idle check: runs every IDLE_CHECK_INTERVAL_SEC seconds.
--- Logs micro-idle events and clears abandoned sessions.
function M.check_idle()
	if not require_state("check_idle") then return end
	if _is_paused() then return end
	local now = hs.timer.absoluteTime() / 1000000

	if _state.session_last_active > 0 then
		local idle_ms = now - _state.session_last_active

		if not _state.is_micro_idle
		and idle_ms > MICRO_IDLE_TIMEOUT_MS
		and idle_ms <= SESSION_TIMEOUT_MS
		then
			_state.is_micro_idle = true
			LogManager.append_log({ type = "idle_start" })
			Logger.debug(LOG, "Micro-idle started (%.0f ms since last keystroke).", idle_ms)
		end

		if idle_ms > SESSION_TIMEOUT_MS then
			if #_state.buffer_events > 0 then LogManager.flush_buffer() end
			LogManager.append_log({
				type        = "session_end",
				duration_ms = _state.session_last_active - _state.session_start_time,
			})
			Logger.debug(LOG, "Typing session ended after %.0f ms of inactivity.", idle_ms)
			_state.session_last_active = 0
			_state.session_start_time  = 0
			_state.is_micro_idle       = false
		end
	end

	poll_system_load()
end

--- Day-rotation check: runs every second via the maintenance timer.
--- When midnight passes, flushes and archives the previous day's data.
function M.perform_maintenance()
	if not require_state("perform_maintenance") then return end
	if _is_paused() then return end
	local today = os.date("%Y-%m-%d")
	if _current_day ~= today then
		Logger.start(LOG, "Midnight rotation: archiving %s…", _current_day)
		-- Credit the part of the current foreground interval that belongs to the
		-- previous calendar day before the log is rotated. Without this split, a
		-- user who stays in one app over midnight has all of that time assigned to
		-- the day of their next app switch.
		local ok_tracker, tracker = pcall(require, "modules.keylogger.context_tracker")
		if ok_tracker and type(tracker.split_active_app_at_midnight) == "function" then
			pcall(tracker.split_active_app_at_midnight, _current_day)
		end
		LogManager.flush_buffer()
		-- New model: day_rollover drains today.log into data.sql + sqlite,
		-- then deletes today.log. The in-memory today_idx / ngram context
		-- are reset because the next day starts fresh — but only once the
		-- drain actually completes. A stalled drain returns false, and every
		-- resumption bookmark (today_idx, ngram_context, _current_day) must
		-- stay untouched so the very next maintenance tick retries the same
		-- rollover instead of silently skipping straight to "today" (G1, G2).
		local rolled_over = LogManager.day_rollover()
		if rolled_over then
			_state.today_idx     = {}
			_state.ngram_context = nil
			_current_day = today
			Logger.success(LOG, "Midnight rotation complete — now tracking %s.", today)
		else
			Logger.warn(LOG, "Midnight rotation stalled — will retry on next maintenance tick.")
		end
	end
	poll_mouse_distance()
end

--- Handles system sleep, wake, lock, and unlock events.
--- @param event number The caffeinate watcher event constant.
function M.caffeinate_cb(event)
	if not require_state("caffeinate_cb") then return end
	if _is_paused() then return end
	local now = hs.timer.absoluteTime() / 1000000
	if event == hs.caffeinate.watcher.systemWillSleep
	or event == hs.caffeinate.watcher.screensDidSleep
	then
		LogManager.log_system_event("sleep", { battery_level = _state.current_battery_level })
		-- Arm passive-time accounting: any wake/unlock will close this window
		_state.passive_started_at  = now
		_state.passive_kind        = "sleep"
		if _state.active_app_name then
			LogManager.log_app_switch(
				_state.active_app_name, "SYSTEM_SLEEP",
				now - (_state.active_app_start or now)
			)
			_state.active_app_name = nil
		end

	elseif event == hs.caffeinate.watcher.systemDidWake
	or     event == hs.caffeinate.watcher.screensDidWake
	then
		LogManager.log_system_event("wake")
		if _state.passive_started_at then
			LogManager.log_passive_period(
				_state.passive_kind or "sleep",
				math.floor(now - _state.passive_started_at)
			)
			_state.passive_started_at = nil
			_state.passive_kind       = nil
		end
		_state.active_app_start = now
		-- macOS can resume without an application-activated notification. The
		-- foreground app must be re-primed or its post-wake interval is omitted
		-- from app_time_ms until the next manual app switch
		hs.timer.doAfter(0.05, function()
			if not _state.active_app_name then
				local ok, tracker = pcall(require, "modules.keylogger.context_tracker")
				if ok and tracker then pcall(tracker.capture_frontmost_app) end
			end
		end)

	elseif event == hs.caffeinate.watcher.screensDidLock then
		LogManager.log_system_event("lock")
		_state.passive_started_at = now
		_state.passive_kind       = "lock"
		if _state.active_app_name then
			LogManager.log_app_switch(
				_state.active_app_name, "SYSTEM_LOCK",
				now - (_state.active_app_start or now)
			)
			_state.active_app_name = nil
		end

	elseif event == hs.caffeinate.watcher.screensDidUnlock then
		LogManager.log_system_event("unlock")
		if _state.passive_started_at then
			LogManager.log_passive_period(
				_state.passive_kind or "lock",
				math.floor(now - _state.passive_started_at)
			)
			_state.passive_started_at = nil
			_state.passive_kind       = nil
		end
		_state.active_app_start = now
		-- Unlock has the same missing-activation edge case as wake. Re-prime
		-- asynchronously so macOS has restored the foreground window first
		hs.timer.doAfter(0.05, function()
			if not _state.active_app_name then
				local ok, tracker = pcall(require, "modules.keylogger.context_tracker")
				if ok and tracker then pcall(tracker.capture_frontmost_app) end
			end
		end)
	end
end

--- Starts WiFi, battery, spaces, and audio device watchers.
function M.init_hardware_watchers()
	if not require_state("init_hardware_watchers") then return end
	Logger.trace(LOG, "Starting hardware watchers…")

	if hs.wifi and hs.wifi.watcher then
		local ok, w = pcall(function()
			return hs.wifi.watcher.new(function()
				if _is_paused() then return end
				local ssid = hs.wifi.currentNetwork()
				LogManager.log_system_event("wifi_change", { ssid = ssid or "Disconnected" })
				Logger.debug(LOG, "Wi-Fi changed: %s.", ssid or "Disconnected")
			end)
		end)
		if ok and w then _wifi_watcher = w; _wifi_watcher:start() end
	end

	if hs.battery and hs.battery.watcher then
		local ok, w = pcall(function()
			return hs.battery.watcher.new(function()
				if _is_paused() then return end
				local level      = hs.battery.percentage()
				local is_charging = hs.battery.isCharging()
				local source     = hs.battery.powerSource()
				_state.current_battery_level = level
				LogManager.log_system_event("power_change", {
					source      = source,
					level       = level,
					is_charging = is_charging,
				})
				Logger.debug(LOG, "Battery: %s%% (%s, charging=%s).",
					tostring(level), tostring(source), tostring(is_charging))
			end)
		end)
		if ok and w then
			_battery_watcher = w
			_battery_watcher:start()
			-- Snapshot current battery level immediately on start
			_state.current_battery_level = hs.battery.percentage()
		end
	end

	if hs.spaces and hs.spaces.watcher then
		pcall(function()
			_spaces_watcher = hs.spaces.watcher.new(function(space_id)
				if _is_paused() then return end
				LogManager.log_system_event("space_change", { space_id = space_id })
			end)
			_spaces_watcher:start()
		end)
	end

	-- Audio device watcher: logs volume and mute changes
	if hs.audiodevice and hs.audiodevice.watcher then
		local ok = pcall(function()
			hs.audiodevice.watcher.setCallback(function(event_code)
				if _is_paused() then return end
				-- "vOut " = output volume changed, "mOut " = output mute toggled
				if event_code == "vOut " or event_code == "mOut " then
					local device = hs.audiodevice.defaultOutputDevice()
					if device then
						local vol   = device:volume()
						local muted = device:muted()
						_state.current_audio_volume = vol
						LogManager.log_system_event("audio_change", {
							volume     = vol,
							muted      = muted,
							event_code = event_code,
						})
						Logger.debug(LOG, "Audio: volume=%.0f%%, muted=%s.", vol or 0, tostring(muted))
					end
				end
			end)
			hs.audiodevice.watcher.start()
			_audio_watcher_active = true
			-- Snapshot current volume immediately
			local device = hs.audiodevice.defaultOutputDevice()
			if device then _state.current_audio_volume = device:volume() end
		end)
		if not ok then Logger.warn(LOG, "Failed to start audio device watcher.") end
	end

	Logger.done(LOG, "Hardware watchers started.")
end

--- Stops all hardware watchers cleanly.
function M.stop_hardware_watchers()
	if not require_state("stop_hardware_watchers") then return end
	Logger.trace(LOG, "Stopping hardware watchers…")
	if _wifi_watcher    then _wifi_watcher:stop();    _wifi_watcher    = nil end
	if _battery_watcher then _battery_watcher:stop(); _battery_watcher = nil end
	if _spaces_watcher  then pcall(function() _spaces_watcher:stop() end); _spaces_watcher = nil end
	if _audio_watcher_active then
		pcall(function() hs.audiodevice.watcher.stop() end)
		_audio_watcher_active = false
	end
	Logger.done(LOG, "Hardware watchers stopped.")
end

return M
