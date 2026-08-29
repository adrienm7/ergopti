--- adapters/timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TimerScheduler port contract defined in
--- static/ergopti_plus/_shared/core/ports/TimerScheduler.spec.js. Wraps explicit
--- hs.timer.new/start ownership behind the four canonical port methods (after, every,
--- cancel, cancelAll) so domain modules can schedule deferred work without a
--- direct dependency on hs.timer.
---
--- FEATURES & RATIONALE:
--- 1. Opaque handles: every scheduled action returns a
---    {timer, fired, committed} table.
---    Callers hold the handle; the adapter tracks all live timers in a strong
---    registry so cancelAll() can drain them without leaking memory.
--- 2. Transactional timers: after() and every() publish one exact unstarted
---    candidate before start(), commit callbacks only after start succeeds, and
---    retain a candidate whose rollback refuses so teardown can retry it.
--- 3. Exception isolation: user callbacks are wrapped in xpcall and routed to
---    the central file logger instead of disappearing in Hammerspoon's runloop.
--- 4. Idempotent cancel: cancel() fences callbacks before native stop and retains
---    the exact handle until stop is proven, including explicit false returns.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.timer_scheduler"


-- =========================================
-- =========================================
-- ======= 1/ Internal State ===============
-- =========================================
-- =========================================

-- Strong table of all live timer handles issued by this adapter instance.
-- Strong references ensure cancelAll() can reach fire-and-forget timers even
-- after the caller drops its handle reference — weak values allowed GC to erase
-- the entry before cancelAll() could call stop() (adapters-input-2).
-- Timers remove themselves from this table on fire (after()) or on cancel().
local _live_timers = {}

-- Monotonically increasing ID used to key entries in _live_timers.
local _next_id = 0

-- `absoluteTime()` is the primary clock, but tests and degraded Hammerspoon
-- environments can temporarily lack it. Each fallback source is mapped onto
-- one process-local logical timeline so a wall-clock correction can neither
-- move elapsed-time consumers backward nor change the origin after recovery.
local _last_monotonic_ns = nil
local _monotonic_sources = {}

local function _new_id()
	_next_id = _next_id + 1
	return _next_id
end

--- Maps one valid native sample onto the process-local monotonic timeline.
--- A source regression shifts only that source's offset; later positive deltas
--- therefore keep advancing without waiting for the wall clock to catch up.
--- @param source string Stable source identity.
--- @param raw_ns number Native timestamp in nanoseconds.
--- @return number|nil timestamp Mapped monotonic timestamp.
local function publish_monotonic_sample(source, raw_ns)
	if type(raw_ns) ~= "number" or raw_ns ~= raw_ns
		or raw_ns == math.huge or raw_ns == -math.huge then
		return nil
	end
	local state = _monotonic_sources[source]
	if state == nil then
		state = {
			offset = _last_monotonic_ns and (_last_monotonic_ns - raw_ns) or 0,
			raw = raw_ns,
		}
		_monotonic_sources[source] = state
	elseif raw_ns < state.raw then
		state.offset = state.offset + (state.raw - raw_ns)
		state.raw = raw_ns
	else
		state.raw = raw_ns
	end

	local mapped = raw_ns + state.offset
	if _last_monotonic_ns ~= nil and mapped < _last_monotonic_ns then
		state.offset = state.offset + (_last_monotonic_ns - mapped)
		mapped = _last_monotonic_ns
	end
	_last_monotonic_ns = mapped
	return mapped
end

--- Invokes one user callback without letting Hammerspoon swallow its failure.
--- @param kind string Scheduler method owning the callback.
--- @param fn function User callback.
local function invoke_callback(kind, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s() callback raised: %s", kind, tostring(err))
	end
end

--- Marks a handle terminal only after no native timer remains owned, then
--- delivers in-memory settlement observers. Observers are not native work: they
--- exist solely to let the exact owner retry a continuation after a previously
--- refused stop is eventually proven settled.
--- @param handle table Scheduler handle.
local function settle_handle(handle)
	local observers = handle.settlement_observers or {}
	handle.settlement_observers = {}
	handle.committed = false
	handle.fired = true
	handle.timer = nil
	if handle.id then _live_timers[handle.id] = nil end
	for _, observer in ipairs(observers) do
		invoke_callback("onSettled", observer)
	end
end

--- Verifies the native running state when the Hammerspoon timer exposes it.
--- Real `hs.timer` objects always provide `running()`. The compatibility branch
--- exists only for narrow injected test doubles implementing the historical
--- start/stop surface; an unreadable real userdata must fail closed.
--- @param timer table|userdata Native timer candidate.
--- @param expected boolean Required running state.
--- @return boolean matches True only when the observable state matches.
--- @return string|nil detail Probe failure detail.
local function native_running_matches(timer, expected)
	local method_ok, method_or_err = pcall(function() return timer.running end)
	if not method_ok then return false, tostring(method_or_err) end
	if type(method_or_err) ~= "function" then
		if type(timer) == "userdata" then return false, "running method unavailable" end
		return true
	end
	local probe_ok, running_or_err = xpcall(function()
		return method_or_err(timer)
	end, debug.traceback)
	if not probe_ok or type(running_or_err) ~= "boolean" then
		return false, tostring(running_or_err)
	end
	if running_or_err ~= expected then
		return false, string.format("running() returned %s", tostring(running_or_err))
	end
	return true
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
--- @return boolean committed True only when the native timer was armed.
function M.after(delaySec, fn)
	local handle = {
		fired = false,
		committed = false,
		id = _new_id(),
		settlement_observers = {},
	}
	local activation_in_progress = true
	local delivered_before_commit = false
	-- Opportunistically retry exact native cleanup debt before adding a new
	-- capability. A refusal must not globally suppress an unrelated timer: the
	-- retained wrapper is already logically inert and retries again on delivery.
	M.retryCleanup()
	local construct_ok, candidate_or_err = xpcall(function()
		return hs.timer.new(delaySec, function()
			-- hs.timer.new() is a repeating primitive. Once the user callback has
			-- fired, a native stop refusal may deliver this wrapper again; use that
			-- delivery only to retry release of the exact native capability.
			if handle.fired == true then
				if handle.timer ~= nil then M.cancel(handle) end
				return
			end
			if handle.committed ~= true then
				if activation_in_progress then
					delivered_before_commit = true
				elseif handle.timer ~= nil then
					-- A start/rollback transaction may have activated before
					-- refusing. Native delivery is then only a cleanup signal:
					-- retry the exact handle without ever invoking user work.
					M.cancel(handle)
				end
				return
			end
			-- The native primitive repeats, so fence delivery before crossing stop().
			-- A refused stop remains exact cleanup debt but can never repeat user work
			handle.fired = true
			handle.committed = false
			M.cancel(handle)
			invoke_callback("after", fn)
		end)
	end, debug.traceback)
	if not construct_ok or candidate_or_err == nil or candidate_or_err == false then
		settle_handle(handle)
		Logger.error(LOG, "after(): hs.timer.new failed — %s.",
			tostring(construct_ok and "returned no handle" or candidate_or_err))
		return handle, false
	end

	-- Ownership must exist before start(): activation may precede a thrown error
	handle.timer = candidate_or_err
	_live_timers[handle.id] = handle
	local start_ok, started_or_err = xpcall(function()
		if type(candidate_or_err.start) ~= "function" then
			error("timer candidate has no start method")
		end
		return candidate_or_err:start()
	end, debug.traceback)
	local state_committed, state_detail = native_running_matches(candidate_or_err, true)
	if not start_ok or not started_or_err or not state_committed or delivered_before_commit then
		activation_in_progress = false
		M.cancel(handle)
		Logger.error(LOG, "after(): native timer start failed — %s.",
			tostring(delivered_before_commit and "callback delivered before commit"
				or (not start_ok and started_or_err)
				or (not started_or_err and "returned false")
				or state_detail))
		return handle, false
	end

	activation_in_progress = false
	handle.committed = true
	return handle, true
end

--- Schedules fn to fire repeatedly every intervalSec seconds.
--- The first firing happens after intervalSec (not immediately).
--- @param intervalSec number Repeat interval in seconds.
--- @param fn function Zero-arity callback to invoke.
--- @return table Opaque cancellation handle.
--- @return boolean committed True only when the native timer was armed.
function M.every(intervalSec, fn)
	local handle = {
		fired = false,
		committed = false,
		id = _new_id(),
		settlement_observers = {},
	}
	local activation_in_progress = true
	local delivered_before_commit = false
	M.retryCleanup()
	local construct_ok, candidate_or_err = xpcall(function()
		return hs.timer.new(intervalSec, function()
			if handle.committed ~= true or handle.fired == true then
				if activation_in_progress then
					delivered_before_commit = true
				elseif handle.timer ~= nil then
					M.cancel(handle)
				end
				return
			end
			invoke_callback("every", fn)
		end)
	end, debug.traceback)
	if not construct_ok or candidate_or_err == nil or candidate_or_err == false then
		settle_handle(handle)
		Logger.error(LOG, "every(): hs.timer.new failed — %s",
			tostring(construct_ok and "returned no handle" or candidate_or_err))
		return handle, false
	end

	-- Ownership must exist before start(): a native implementation may activate
	-- and then raise, leaving only this exact candidate capable of stopping it
	handle.timer = candidate_or_err
	_live_timers[handle.id] = handle
	local start_ok, started_or_err = xpcall(function()
		if type(candidate_or_err.start) ~= "function" then
			error("timer candidate has no start method")
		end
		return candidate_or_err:start()
	end, debug.traceback)
	local state_committed, state_detail = native_running_matches(candidate_or_err, true)
	if not start_ok or not started_or_err or not state_committed or delivered_before_commit then
		activation_in_progress = false
		-- M.cancel() fences before crossing stop(), and deliberately retains the
		-- candidate when the exact rollback throws or returns false
		M.cancel(handle)
		Logger.error(LOG, "every(): native timer start failed — %s",
			tostring(delivered_before_commit and "callback delivered before commit"
				or (not start_ok and started_or_err)
				or (not started_or_err and "returned false")
				or state_detail))
		return handle, false
	end

	activation_in_progress = false
	handle.committed = true
	return handle, true
end

--- Registers one in-memory continuation that runs exactly once after the native
--- timer is proven stopped. If settlement already committed, it runs now.
--- @param handle table Scheduler handle returned by after()/every().
--- @param observer function Zero-arity continuation.
--- @return boolean registered
function M.onSettled(handle, observer)
	if type(handle) ~= "table" or type(observer) ~= "function" then return false end
	if handle.timer == nil then
		invoke_callback("onSettled", observer)
		return true
	end
	if type(handle.settlement_observers) ~= "table" then
		handle.settlement_observers = {}
	end
	handle.settlement_observers[#handle.settlement_observers + 1] = observer
	return true
end

--- Cancels a previously scheduled timer. Safe to call on a nil or already-fired
--- handle — matches the contract's "ignore" error behavior.
--- @param handle table|nil Cancellation token returned by after() or every().
--- @return boolean settled True when no live native timer remains.
function M.cancel(handle)
	if type(handle) ~= "table" or not handle.timer then return true end
	-- Fence first because a callback may already be queued when native stop fails
	handle.committed = false
	local stopped, result_or_err = xpcall(function() return handle.timer:stop() end, debug.traceback)
	local state_settled, state_detail = native_running_matches(handle.timer, false)
	if not stopped or result_or_err == false or not state_settled then
		-- Retain both the public handle and its live-set entry. A later teardown is
		-- the only owner that can retry this exact native timer capability.
		Logger.error(LOG, "cancel(): native timer stop failed; retained for retry — %s.",
			tostring(not stopped and result_or_err
				or (result_or_err == false and "returned false")
				or state_detail))
		return false
	end
	settle_handle(handle)
	return true
end

--- Retries only uncommitted native timers retained after a failed rollback.
--- Live repeating timers are deliberately excluded: they are active resources,
--- not cleanup debt, and must not prevent unrelated timers from being created.
--- @return boolean settled True when no rollback debt remains.
function M.retryCleanup()
	local snapshot = {}
	for _, handle in pairs(_live_timers) do
		if handle.timer ~= nil and handle.committed ~= true then
			snapshot[#snapshot + 1] = handle
		end
	end
	local all_stopped = true
	for _, handle in ipairs(snapshot) do
		if M.cancel(handle) ~= true then all_stopped = false end
	end
	return all_stopped
end

--- Cancels every timer owned by this scheduler instance.
--- Safe to call at any time, including before any timers are scheduled.
--- @return boolean settled True only when every native timer stopped.
function M.cancelAll()
	local snapshot = {}
	for _, handle in pairs(_live_timers) do
		snapshot[#snapshot + 1] = handle
	end
	local all_stopped = true
	for _, handle in ipairs(snapshot) do
		if M.cancel(handle) ~= true then all_stopped = false end
	end
	return all_stopped
end

--- Returns the number of currently live (non-cancelled, non-fired) timers
--- tracked by this adapter instance. Intended for diagnostics and tests.
--- @return integer Count of active timer handles.
function M.activeCount()
	local count = 0
	for _, handle in pairs(_live_timers) do
		if handle and handle.timer ~= nil then
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

--- Returns a high-resolution monotonic timestamp in nanoseconds. Wraps
--- hs.timer.absoluteTime() (the macOS analog of QueryPerformanceCounter) so the
--- sub-millisecond hot-path profiler has no direct hs.timer dependency. A
--- degraded wall-clock sample is rebased onto the same logical timeline when
--- absoluteTime is unavailable, then source regressions are offset locally.
--- @return number Nanoseconds from an arbitrary monotonic origin.
function M.now_ns()
	if hs and hs.timer and hs.timer.absoluteTime then
		local ok, t = pcall(hs.timer.absoluteTime)
		local mapped = ok and publish_monotonic_sample("absolute", t) or nil
		if mapped ~= nil then return mapped end
	end
	local wall = M.now()
	local mapped = publish_monotonic_sample("wall", wall * 1e9)
	if mapped ~= nil then return mapped end
	return _last_monotonic_ns or (os.time() * 1e9)
end

--- Returns suspend-paused monotonic time in seconds. Native absolute time is
--- independent of wall-clock corrections and does not spend duration budgets
--- while the Mac is asleep; the mapped fallback preserves a nondecreasing
--- process-local timeline when that capability is temporarily unavailable.
--- @return number Seconds from an arbitrary monotonic origin.
function M.awake_time()
	return M.now_ns() / 1e9
end

--- Suspends execution for the given number of microseconds.
--- Wraps hs.timer.usleep(). Use sparingly — this blocks the Lua thread.
--- @param microseconds integer Number of microseconds to sleep.
function M.sleep_us(microseconds)
	if type(microseconds) ~= "number" or microseconds <= 0 then return end
	pcall(hs.timer.usleep, math.floor(microseconds))
end

return M
