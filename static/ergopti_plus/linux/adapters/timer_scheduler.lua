--- static/ergopti_plus/linux/adapters/timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TimerScheduler port contract defined in
--- static/ergopti_plus/shared/ports/TimerScheduler.spec.js. Provides the four
--- canonical port methods (after, every, cancel, cancelAll) using LuaJIT's
--- luv (libuv) timer handles so domain modules can schedule deferred work
--- without a direct dependency on any OS-level timer API.
---
--- FEATURES & RATIONALE:
--- 1. libuv backend: luv timers are integrated with the event loop and avoid
---    the busy-wait overhead of os.clock-based polling. Each handle maps to
---    a uv_timer_t under the hood.
--- 2. Opaque handles: every scheduled action returns a {timer, fired} table.
---    Callers hold the handle; cancelAll() drains a weak registry.
--- 3. Exception isolation: the user callback is wrapped in pcall so a crash
---    inside fn never propagates to the libuv event loop.
--- 4. Idempotent cancel: cancel() on a nil, already-fired, or already-cancelled
---    handle is a silent no-op, matching the contract's "ignore" error behavior.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.timer_scheduler"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Weak-value table of all live timer handles issued by this adapter instance.
-- Using weak references prevents the registry from keeping timers alive after
-- all other references are dropped.
local _live_timers = setmetatable({}, { __mode = "v" })

-- Monotonically increasing ID used to key entries in _live_timers.
local _next_id = 0

local function _new_id()
	_next_id = _next_id + 1
	return _next_id
end

-- luv is the LuaJIT libuv binding (lua-luv package on most Linux distros).
-- TODO(linux): replace this stub loader with the real luv require once the
-- package is declared in the vendor/ directory.
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end


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
	-- TODO(linux): implement using luv.new_timer() + luv.timer_start() with repeat=0
	if not luv then
		Logger.warn(LOG, "after(): luv not available — timer silently dropped.")
		return handle
	end
	local ok, timer_or_err = pcall(function()
		local t = luv.new_timer()
		local delay_ms = math.max(0, math.floor(delaySec * 1000))
		luv.timer_start(t, delay_ms, 0, function()
			handle.fired = true
			luv.timer_stop(t)
			luv.close(t)
			local ok_fn, err = pcall(fn)
			if not ok_fn then
				Logger.error(LOG, "after() callback raised: %s", tostring(err))
			end
		end)
		return t
	end)
	if not ok then
		Logger.error(LOG, "after(): luv.new_timer failed — %s", tostring(timer_or_err))
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
	-- TODO(linux): implement using luv.new_timer() + luv.timer_start() with repeat=interval
	if not luv then
		Logger.warn(LOG, "every(): luv not available — timer silently dropped.")
		return handle
	end
	local ok, timer_or_err = pcall(function()
		local t = luv.new_timer()
		local interval_ms = math.max(1, math.floor(intervalSec * 1000))
		luv.timer_start(t, interval_ms, interval_ms, function()
			local ok_fn, err = pcall(fn)
			if not ok_fn then
				Logger.error(LOG, "every() callback raised: %s", tostring(err))
			end
		end)
		return t
	end)
	if not ok then
		Logger.error(LOG, "every(): luv.new_timer failed — %s", tostring(timer_or_err))
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
	pcall(function()
		if luv then
			luv.timer_stop(handle.timer)
			luv.close(handle.timer)
		end
	end)
	handle.fired = true
	if handle.id then _live_timers[handle.id] = nil end
end

--- Cancels every timer owned by this scheduler instance.
--- Safe to call at any time, including before any timers are scheduled.
function M.cancelAll()
	for id, handle in pairs(_live_timers) do
		if handle and handle.timer and luv then
			pcall(function()
				luv.timer_stop(handle.timer)
				luv.close(handle.timer)
			end)
			handle.fired = true
		end
		_live_timers[id] = nil
	end
end

return M
