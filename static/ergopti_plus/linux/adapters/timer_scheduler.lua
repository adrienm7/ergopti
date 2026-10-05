--- adapters/timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TimerScheduler port contract defined in
--- static/ergopti_plus/_shared/core/ports/TimerScheduler.spec.js. Provides the four
--- canonical port methods (after, every, cancel, cancelAll) using LuaJIT's
--- luv (libuv) timer handles so domain modules can schedule deferred work
--- without a direct dependency on any OS-level timer API.
---
--- FEATURES & RATIONALE:
--- 1. libuv backend: luv timers are integrated with the event loop and avoid
---    the busy-wait overhead of os.clock-based polling. Each handle maps to
---    a uv_timer_t under the hood.
--- 2. Opaque handles: every scheduled action returns a {timer, fired} table.
---    Callers can hold the handle; cancelAll() drains the scheduler's registry.
--- 3. Exception isolation: the user callback is wrapped in pcall so a crash
---    inside fn never propagates to the libuv event loop.
--- 4. Idempotent cancel: cancel() on a nil, already-fired, or already-cancelled
---    handle is a silent no-op, matching the contract's "ignore" error behavior.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local NativeTimer = require("infra.native_timer")
local NumberPolicy = require("number_policy")

local LOG = "adapters.timer_scheduler"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- The scheduler owns every armed token until firing or accepted cancellation.
-- Weak values let GC erase a fire-and-forget repeater while its native timer
-- remained live, making cancelAll() report success without stopping it.
local _live_timers = {}

-- Monotonically increasing ID used to key entries in _live_timers.
local _next_id = 0

local function _new_id()
	_next_id = _next_id + 1
	return _next_id
end

--- Converts an admitted finite duration before any native allocation.
--- @param seconds any Duration in seconds.
--- @param minimum_ms number Existing method-specific finite clamping floor.
--- @return number|nil milliseconds Finite normalized duration, or refusal.
local function _duration_ms(seconds, minimum_ms)
	if not NumberPolicy.is_finite(seconds) then return nil end
	local milliseconds = seconds * 1000
	if not NumberPolicy.is_finite(milliseconds) then return nil end
	return math.max(minimum_ms, math.floor(milliseconds))
end

-- luv is the LuaJIT libuv binding (lua-luv package on most Linux distros).
-- TODO(linux): replace this stub loader with the real luv require once the
-- package is declared in the vendor/ directory.
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end

M.HAS_ASYNC = luv ~= nil

--- Number of timers that are actually armed.
--- @return integer
function M.activeCount()
	local count = 0
	for _, handle in pairs(_live_timers) do
		if handle and handle.armed == true then count = count + 1 end
	end
	return count
end


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Schedules fn to fire once after delaySec seconds.
--- @param delaySec number Delay in seconds (fractional values accepted).
--- @param fn function Zero-arity callback to invoke.
--- @return table Opaque cancellation handle.
function M.after(delaySec, fn)
	local handle = { fired = false, armed = false, id = _new_id() }
	if type(fn) ~= "function" then
		Logger.error(LOG, "after(): callback must be a function — timer rejected.")
		handle.fired = true
		return handle
	end
	local delay_ms = _duration_ms(delaySec, 0)
	if delay_ms == nil then
		Logger.error(LOG, "after(): duration must be finite in seconds and milliseconds — timer rejected.")
		handle.fired = true
		return handle
	end
	if not luv then
		Logger.error(LOG, "after(): luv not available — timer was not armed.")
		handle.fired = true
		return handle
	end
	local allocated_timer = nil
	local ok, timer_or_err = pcall(function()
		local t = assert(luv.new_timer(), "luv.new_timer returned nil")
		allocated_timer = t
		local started = NativeTimer.start(luv, t, delay_ms, 0, function()
			handle.fired = true
			handle.armed = false
			_live_timers[handle.id] = nil
			local cleanup_ok, cleanup_error = pcall(function()
				luv.timer_stop(t)
				luv.close(t)
			end)
			if cleanup_ok then
				handle.timer = nil
			else
				_live_timers[handle.id] = handle
				Logger.error(LOG, "after(): fired timer cleanup retained — %s",
					tostring(cleanup_error))
			end
			local ok_fn, err = pcall(fn)
			if not ok_fn then
				Logger.error(LOG, "after() callback raised: %s", tostring(err))
			end
		end)
		if started == false or started == nil then error("luv.timer_start rejected the timer") end
		return t
	end)
	if not ok then
		if allocated_timer then pcall(luv.close, allocated_timer) end
		Logger.error(LOG, "after(): timer allocation/start failed — %s", tostring(timer_or_err))
		handle.fired = true
		return handle
	end
	handle.timer = timer_or_err
	handle.armed = true
	_live_timers[handle.id] = handle
	return handle
end

--- Schedules fn to fire repeatedly every intervalSec seconds.
--- The first firing happens after intervalSec (not immediately).
--- @param intervalSec number Repeat interval in seconds.
--- @param fn function Zero-arity callback to invoke.
--- @return table Opaque cancellation handle.
function M.every(intervalSec, fn)
	local handle = { fired = false, armed = false, id = _new_id() }
	if type(fn) ~= "function" then
		Logger.error(LOG, "every(): callback must be a function — timer rejected.")
		handle.fired = true
		return handle
	end
	local interval_ms = _duration_ms(intervalSec, 1)
	if interval_ms == nil then
		Logger.error(LOG, "every(): duration must be finite in seconds and milliseconds — timer rejected.")
		handle.fired = true
		return handle
	end
	if not luv then
		Logger.error(LOG, "every(): luv not available — timer was not armed.")
		handle.fired = true
		return handle
	end
	local allocated_timer = nil
	local ok, timer_or_err = pcall(function()
		local t = assert(luv.new_timer(), "luv.new_timer returned nil")
		allocated_timer = t
		local started = NativeTimer.start(luv, t, interval_ms, interval_ms, function()
			local ok_fn, err = pcall(fn)
			if not ok_fn then
				Logger.error(LOG, "every() callback raised: %s", tostring(err))
			end
		end)
		if started == false or started == nil then error("luv.timer_start rejected the timer") end
		return t
	end)
	if not ok then
		if allocated_timer then pcall(luv.close, allocated_timer) end
		Logger.error(LOG, "every(): timer allocation/start failed — %s", tostring(timer_or_err))
		handle.fired = true
		return handle
	end
	handle.timer = timer_or_err
	handle.armed = true
	_live_timers[handle.id] = handle
	return handle
end

--- Cancels a previously scheduled timer. Safe to call on a nil or already-fired
--- handle — matches the contract's "ignore" error behavior.
--- @param handle table|nil Cancellation token returned by after() or every().
function M.cancel(handle)
	if type(handle) ~= "table" or not handle.timer then return true end
	local ok, err = pcall(function()
		if luv then
			luv.timer_stop(handle.timer)
			luv.close(handle.timer)
		end
	end)
	if not ok then
		Logger.error(LOG, "cancel(): timer ownership retained — %s", tostring(err))
		return false
	end
	handle.fired = true
	handle.armed = false
	handle.timer = nil
	if handle.id then _live_timers[handle.id] = nil end
	return true
end

--- Cancels every timer owned by this scheduler instance.
--- Safe to call at any time, including before any timers are scheduled.
function M.cancelAll()
	local cancelled = true
	for id, handle in pairs(_live_timers) do
		if handle and handle.timer and luv then
			local ok, err = pcall(function()
				luv.timer_stop(handle.timer)
				luv.close(handle.timer)
			end)
			if ok then
				handle.fired = true
				handle.armed = false
				handle.timer = nil
			else
				cancelled = false
				Logger.error(LOG, "cancelAll(): timer %s ownership retained — %s",
					tostring(id), tostring(err))
			end
		end
		if handle and handle.timer == nil then _live_timers[id] = nil end
	end
	return cancelled
end

return M
