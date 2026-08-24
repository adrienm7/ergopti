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
local TimerScheduler = require("adapters.timer_scheduler")
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
-- macOS needs one runloop turn after wake/unlock before AX reports foreground truth
local CONTEXT_REFRESH_DELAY_SEC = 0.05

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
local _audio_callback_installed = false
local _hardware_watchers_enabled = false
local _hardware_generation = 0
local _context_refresh_generation = 0

-- Wake/unlock continuations share the hardware lifecycle. A handle remains in
-- this table until TimerScheduler confirms exact native cancellation.
local _context_refresh_timers = {}

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
		return false
	end
	if type(is_paused_fn) ~= "function" then
		Logger.error(LOG, "M.init(): is_paused_fn must be a function — watchers non-functional.")
		return false
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return _state == core_state and _is_paused == is_paused_fn
	end
	_state     = core_state
	_is_paused = is_paused_fn
	Logger.success(LOG, "Keylogger watchers initialized.")
	return true
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

--- Returns whether one hardware callback still belongs to the live runtime.
--- @param generation integer Generation captured when its watcher was created.
--- @return boolean allowed True only for the committed, enabled generation.
local function hardware_callback_allowed(generation)
	return _hardware_watchers_enabled == true
		and generation == _hardware_generation
		and _state ~= nil
		and _state.is_enabled == true
		and not _is_paused()
end

--- Contains a native hardware callback and routes failures to the file logger.
--- @param label string Hardware source for diagnostics.
--- @param generation integer Generation captured by the callback.
--- @param callback function Callback body.
local function run_hardware_callback(label, generation, callback)
	local ok, err = xpcall(function()
		if not hardware_callback_allowed(generation) then return end
		callback()
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s watcher callback failed: %s.", label, tostring(err))
	end
end

--- Cancels every wake/unlock continuation while retaining refused handles.
--- @return boolean settled True only when every exact timer was released.
local function cancel_context_refresh_timers()
	local snapshot = {}
	for handle in pairs(_context_refresh_timers) do
		snapshot[#snapshot + 1] = handle
	end
	local settled = true
	for _, handle in ipairs(snapshot) do
		local ok, cancelled = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if ok and cancelled == true then
			_context_refresh_timers[handle] = nil
		else
			settled = false
			Logger.error(LOG,
				"Context-refresh timer cleanup failed; exact timer retained: %s.",
				tostring(ok and cancelled or cancelled))
		end
	end
	return settled
end

--- Schedules one lifecycle-owned post-wake foreground-context refresh.
--- @param reason string Wake or unlock diagnostic label.
--- @return boolean committed True only when a timer owns the continuation.
local function schedule_context_refresh(reason)
	_context_refresh_generation = _context_refresh_generation + 1
	local refresh_generation = _context_refresh_generation
	local hardware_generation = _hardware_generation
	local timer_committed = false
	if not cancel_context_refresh_timers() then
		_state.is_secure_field = true
		Logger.error(LOG, "%s context refresh blocked by prior timer cleanup debt.", reason)
		return false
	end

	local handle
	local scheduled, candidate, committed = xpcall(function()
		return TimerScheduler.after(CONTEXT_REFRESH_DELAY_SEC, function()
			if timer_committed ~= true then return end
			-- TimerScheduler fences the user callback before native stop. A refused
			-- stop leaves handle.timer live; retain it and fail closed until teardown
			if handle and handle.timer ~= nil then
				_state.is_secure_field = true
				Logger.error(LOG,
					"%s context refresh blocked by timer cleanup debt.", reason)
				return
			end
			if handle then _context_refresh_timers[handle] = nil end
			if refresh_generation ~= _context_refresh_generation
			or hardware_generation ~= _hardware_generation
			or _hardware_watchers_enabled ~= true
			or _state == nil
			or _state.is_enabled ~= true
			or _is_paused()
			then
				return
			end
			if _state.active_app_name then return end

			local ok_tracker, tracker = pcall(require, "modules.keylogger.context_tracker")
			if not ok_tracker or type(tracker) ~= "table"
			or type(tracker.capture_frontmost_app) ~= "function"
			then
				_state.is_secure_field = true
				Logger.error(LOG, "%s context refresh could not load the context tracker.", reason)
				return
			end
			local ok_capture, captured = xpcall(tracker.capture_frontmost_app, debug.traceback)
			if not ok_capture or captured ~= true then
				_state.is_secure_field = true
				Logger.error(LOG, "%s context refresh failed: %s.", reason,
					tostring(ok_capture and captured or captured))
			end
		end)
	end, debug.traceback)
	handle = candidate
	if type(handle) == "table" then _context_refresh_timers[handle] = true end
	if not scheduled or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" then
			local cancel_ok, cancelled = xpcall(function()
				return TimerScheduler.cancel(handle)
			end, debug.traceback)
			if cancel_ok and cancelled == true then
				_context_refresh_timers[handle] = nil
			end
		end
		_state.is_secure_field = true
		Logger.error(LOG, "%s context refresh timer was not committed: %s.", reason,
			tostring(scheduled and committed or candidate))
		return false
	end
	timer_committed = true
	return true
end

--- Stops one retained object watcher and clears it only after exact success.
--- Hammerspoon's object watchers return themselves from start() and stop().
--- @param handle table|userdata|nil Native watcher candidate.
--- @param clear function Clears the owning field after stop commitment.
--- @return boolean settled True only when no native watcher remains owned.
local function stop_object_watcher(handle, clear)
	if not handle then return true end
	local ok, result = xpcall(function()
		if type(handle.stop) ~= "function" then error("watcher has no stop method") end
		return handle:stop()
	end, debug.traceback)
	if not ok or (result ~= true and result ~= handle) then
		Logger.error(LOG, "Hardware watcher stop failed; exact handle retained: %s.",
			tostring(ok and result or result))
		return false
	end
	clear()
	return true
end

--- Stops the singleton audio watcher and removes its installed callback.
--- @return boolean settled True only when both resources are released.
local function stop_audio_watcher()
	local watcher = hs.audiodevice and hs.audiodevice.watcher
	if not _audio_watcher_active and not _audio_callback_installed then return true end
	if not watcher then return false end

	if _audio_watcher_active then
		local ok_stop, stop_err = xpcall(watcher.stop, debug.traceback)
		local ok_state, running = xpcall(watcher.isRunning, debug.traceback)
		if not ok_stop or not ok_state or running ~= false then
			Logger.error(LOG, "Audio watcher stop failed; ownership retained: %s.",
				tostring(not ok_stop and stop_err or running))
			return false
		end
		_audio_watcher_active = false
	end

	if _audio_callback_installed then
		local ok_callback, callback_err = xpcall(function()
			watcher.setCallback(nil)
		end, debug.traceback)
		if not ok_callback then
			Logger.error(LOG, "Audio watcher callback removal failed: %s.",
				tostring(callback_err))
			return false
		end
		_audio_callback_installed = false
	end
	return true
end

--- Releases every hardware capability independently so one refusal cannot hide
--- cleanup opportunities for its siblings.
--- @return boolean settled True only when every exact capability was released.
local function cleanup_hardware_resources()
	local settled = true
	if not stop_audio_watcher() then settled = false end
	if not stop_object_watcher(_spaces_watcher, function() _spaces_watcher = nil end) then
		settled = false
	end
	if not stop_object_watcher(_battery_watcher, function() _battery_watcher = nil end) then
		settled = false
	end
	if not stop_object_watcher(_wifi_watcher, function() _wifi_watcher = nil end) then
		settled = false
	end
	return settled
end

--- Creates and starts one object watcher while publishing ownership first.
--- @param label string Hardware source for diagnostics.
--- @param constructor function Native watcher constructor.
--- @param publish function Stores the candidate in its lifecycle field.
--- @return boolean committed True only when native start returned its handle.
local function start_object_watcher(label, constructor, publish)
	local ok_new, candidate = xpcall(constructor, debug.traceback)
	if not ok_new or candidate == nil or candidate == false then
		Logger.error(LOG, "%s watcher construction failed: %s.", label, tostring(candidate))
		return false
	end
	publish(candidate)
	local ok_start, result = xpcall(function()
		if type(candidate.start) ~= "function" then error("watcher has no start method") end
		return candidate:start()
	end, debug.traceback)
	if not ok_start or (result ~= true and result ~= candidate) then
		Logger.error(LOG, "%s watcher start failed: %s.", label,
			tostring(ok_start and result or result))
		return false
	end
	return true
end

--- Handles system sleep, wake, lock, and unlock events.
--- @param event number The caffeinate watcher event constant.
function M.caffeinate_cb(event)
	if not require_state("caffeinate_cb") then return false end
	local callback_ok, result_or_err = xpcall(function()
		if _state.is_enabled ~= true or _hardware_watchers_enabled ~= true or _is_paused() then
			return true
		end
		local now = hs.timer.absoluteTime() / 1000000
		if event == hs.caffeinate.watcher.systemWillSleep
		or event == hs.caffeinate.watcher.screensDidSleep
		then
			LogManager.log_system_event("sleep", { battery_level = _state.current_battery_level })
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
			schedule_context_refresh("Wake")

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
			schedule_context_refresh("Unlock")
		end
		return true
	end, debug.traceback)
	if not callback_ok then
		_state.is_secure_field = true
		Logger.error(LOG, "Caffeinate watcher callback failed: %s.", tostring(result_or_err))
		return false
	end
	return result_or_err == true
end

--- Starts Wi-Fi, battery, spaces, and audio device watchers as one transaction.
--- @return boolean committed True only when every available watcher committed.
function M.init_hardware_watchers()
	if not require_state("init_hardware_watchers") then return false end
	if _hardware_watchers_enabled then return true end
	Logger.debug(LOG, "Starting hardware watcher transaction…")

	_hardware_generation = _hardware_generation + 1
	_context_refresh_generation = _context_refresh_generation + 1
	if not cancel_context_refresh_timers() or not cleanup_hardware_resources() then
		Logger.error(LOG, "Hardware watcher start refused: prior cleanup remains pending.")
		return false
	end
	local generation = _hardware_generation

	local committed, commit_err = xpcall(function()
		if hs.wifi and hs.wifi.watcher then
			if not start_object_watcher("Wi-Fi", function()
				return hs.wifi.watcher.new(function()
					run_hardware_callback("Wi-Fi", generation, function()
						local ssid = hs.wifi.currentNetwork()
						LogManager.log_system_event("wifi_change", {
							ssid = ssid or "Disconnected",
						})
						Logger.debug(LOG, "Wi-Fi changed: %s.", ssid or "Disconnected")
					end)
				end)
			end, function(candidate) _wifi_watcher = candidate end) then
				error("Wi-Fi watcher refused startup")
			end
		end

		if hs.battery and hs.battery.watcher then
			if not start_object_watcher("Battery", function()
				return hs.battery.watcher.new(function()
					run_hardware_callback("Battery", generation, function()
						local level       = hs.battery.percentage()
						local is_charging = hs.battery.isCharging()
						local source      = hs.battery.powerSource()
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
			end, function(candidate) _battery_watcher = candidate end) then
				error("battery watcher refused startup")
			end
			local ok_level, level = pcall(hs.battery.percentage)
			if ok_level then _state.current_battery_level = level end
		end

		if hs.spaces and hs.spaces.watcher then
			if not start_object_watcher("Spaces", function()
				return hs.spaces.watcher.new(function(space_id)
					run_hardware_callback("Spaces", generation, function()
						LogManager.log_system_event("space_change", { space_id = space_id })
					end)
				end)
			end, function(candidate) _spaces_watcher = candidate end) then
				error("spaces watcher refused startup")
			end
		end

		if hs.audiodevice and hs.audiodevice.watcher then
			local watcher = hs.audiodevice.watcher
			if type(watcher.setCallback) ~= "function"
			or type(watcher.start) ~= "function"
			or type(watcher.stop) ~= "function"
			or type(watcher.isRunning) ~= "function"
			then
				error("audio watcher lifecycle API is incomplete")
			end
			-- Publish possible ownership first because setCallback may install the
			-- function and then throw, leaving rollback as the only remover
			_audio_callback_installed = true
			watcher.setCallback(function(event_code)
				run_hardware_callback("Audio", generation, function()
					if event_code ~= "vOut " and event_code ~= "mOut " then return end
					local device = hs.audiodevice.defaultOutputDevice()
					if not device then return end
					local volume = device:volume()
					local muted = device:muted()
					_state.current_audio_volume = volume
					LogManager.log_system_event("audio_change", {
						volume     = volume,
						muted      = muted,
						event_code = event_code,
					})
					Logger.debug(LOG, "Audio: volume=%.0f%%, muted=%s.",
						volume or 0, tostring(muted))
				end)
			end)
			-- Publish possible ownership before start because native activation can
			-- precede a thrown error and the singleton exposes no returned handle
			_audio_watcher_active = true
			watcher.start()
			if watcher.isRunning() ~= true then error("audio watcher did not start") end

			local ok_device, device = pcall(hs.audiodevice.defaultOutputDevice)
			if ok_device and device then
				local ok_volume, volume = pcall(function() return device:volume() end)
				if ok_volume then _state.current_audio_volume = volume end
			end
		end
	end, debug.traceback)

	if not committed then
		_hardware_generation = _hardware_generation + 1
		_hardware_watchers_enabled = false
		local rolled_back = cleanup_hardware_resources()
		Logger.error(LOG, "Hardware watcher transaction failed: %s.", tostring(commit_err))
		if not rolled_back then
			Logger.error(LOG, "Hardware watcher rollback remains incomplete.")
		end
		return false
	end

	_hardware_watchers_enabled = true
	Logger.debug(LOG, "Hardware watcher transaction committed.")
	return true
end

--- Stops all hardware watchers and post-wake continuations cleanly.
--- @return boolean settled True only when every owned capability was released.
function M.stop_hardware_watchers()
	if not require_state("stop_hardware_watchers") then return false end
	Logger.debug(LOG, "Stopping hardware watcher transaction…")
	_hardware_watchers_enabled = false
	_hardware_generation = _hardware_generation + 1
	_context_refresh_generation = _context_refresh_generation + 1
	local timers_stopped = cancel_context_refresh_timers()
	local watchers_stopped = cleanup_hardware_resources()
	local settled = timers_stopped and watchers_stopped
	if settled then
		Logger.debug(LOG, "Hardware watcher transaction stopped.")
	else
		Logger.error(LOG, "Hardware watcher cleanup remains pending.")
	end
	return settled
end

return M
