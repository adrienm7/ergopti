--- adapters/timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TimerScheduler port contract defined in
--- static/ergopti_plus/shared/ports/TimerScheduler.spec.js. Wraps hs.timer.doAfter
--- and hs.timer.doEvery behind the four canonical port methods (after, every,
--- cancel, cancelAll) so domain modules can schedule deferred work without a
--- direct dependency on hs.timer.
---
--- FEATURES & RATIONALE:
--- 1. Opaque handles: every scheduled action returns a {timer, fired} table.
---    Callers hold the handle; the adapter tracks all live timers in a weak
---    registry so cancelAll() can drain them without leaking memory.
--- 2. Exception isolation: the user callback is wrapped in pcall so a crash
---    inside fn never propagates to the Hammerspoon runloop.
--- 3. Idempotent cancel: cancel() on a nil, already-fired, or already-cancelled
---    handle is a silent no-op, matching the contract's "ignore" error behavior.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.timer_scheduler"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Weak-value table of all live timer handles issued by this adapter instance.
-- Using weak references prevents the registry itself from keeping timers alive
-- after all other references are dropped.
local _live_timers = setmetatable({}, { __mode = "v" })

-- Monotonically increasing ID used to key entries in _live_timers.
local _next_id = 0

local function _new_id()
	_next_id = _next_id + 1
	return _next_id
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
	local handle = { fired = false, id = _new_id() }
	local ok, timer_or_err = pcall(hs.timer.doAfter, delaySec, function()
		handle.fired = true
		local ok_fn, err = pcall(fn)
		if not ok_fn then
			Logger.error(LOG, "after() callback raised: %s", tostring(err))
		end
	end)
	if not ok then
		Logger.error(LOG, "after(): hs.timer.doAfter failed — %s", tostring(timer_or_err))
		return handle
	end
	handle.timer = timer_or_err
	_live_timers[handle.id] = handle
	return handle
end

--- Schedules fn to fire repeatedly every intervalSec seconds.
--- The first firing happens after intervalSec (not immediately).
--- @param intervalSec number Repeat interval in seconds.
--- @param fn function Zero-arity callback to invoke.
--- @return table Opaque cancellation handle.
function M.every(intervalSec, fn)
	local handle = { fired = false, id = _new_id() }
	local ok, timer_or_err = pcall(hs.timer.doEvery, intervalSec, function()
		local ok_fn, err = pcall(fn)
		if not ok_fn then
			Logger.error(LOG, "every() callback raised: %s", tostring(err))
		end
	end)
	if not ok then
		Logger.error(LOG, "every(): hs.timer.doEvery failed — %s", tostring(timer_or_err))
		return handle
	end
	handle.timer = timer_or_err
	_live_timers[handle.id] = handle
	return handle
end

--- Cancels a previously scheduled timer. Safe to call on a nil or already-fired
--- handle — matches the contract's "ignore" error behavior.
--- @param handle table|nil Cancellation token returned by after() or every().
function M.cancel(handle)
	if type(handle) ~= "table" or not handle.timer then return end
	pcall(function() handle.timer:stop() end)
	handle.fired = true
	if handle.id then _live_timers[handle.id] = nil end
end

--- Cancels every timer owned by this scheduler instance.
--- Safe to call at any time, including before any timers are scheduled.
function M.cancelAll()
	for id, handle in pairs(_live_timers) do
		if handle and handle.timer then
			pcall(function() handle.timer:stop() end)
			handle.fired = true
		end
		_live_timers[id] = nil
	end
end

--- Returns the number of currently live (non-cancelled, non-fired) timers
--- tracked by this adapter instance. Intended for diagnostics and tests.
--- @return integer Count of active timer handles.
function M.activeCount()
	local count = 0
	for _, handle in pairs(_live_timers) do
		if handle and not handle.fired then
			count = count + 1
		end
	end
	return count
end

--- Returns the current wall-clock time in seconds since the Unix epoch.
--- Fractional seconds are included (e.g. 1716000000.123). Wraps
--- hs.timer.secondsSinceEpoch() so callers have no direct hs.timer dependency.
--- @return number Seconds since epoch as a floating-point value.
function M.now()
	local ok, t = pcall(hs.timer.secondsSinceEpoch)
	return ok and t or os.time()
end

--- Suspends execution for the given number of microseconds.
--- Wraps hs.timer.usleep(). Use sparingly — this blocks the Lua thread.
--- @param microseconds integer Number of microseconds to sleep.
function M.sleep_us(microseconds)
	if type(microseconds) ~= "number" or microseconds <= 0 then return end
	pcall(hs.timer.usleep, math.floor(microseconds))
end

return M
