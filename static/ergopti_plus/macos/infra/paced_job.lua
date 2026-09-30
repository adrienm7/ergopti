--- infra/paced_job.lua

--- ==============================================================================
--- MODULE: Paced Job
--- DESCRIPTION:
--- Runs one long computation on the Hammerspoon main thread in bounded slices.
--- The body executes inside a coroutine and calls `pacer.pause()` at safe
--- points; once the slice budget is spent the job yields and resumes on a
--- later timer turn, so event taps, watchdogs and WebKit presentation keep
--- running between slices.
---
--- FEATURES & RATIONALE:
--- 1. Never inline: the first slice always starts from a timer, so a caller
---    that opens a window and starts a job returns before any work runs.
--- 2. Bounded slices: `pause()` yields only after `slice_ms` of work, keeping
---    the cost of a pause check to one clock read.
--- 3. Explicit ownership: a job settles exactly once through `on_done`; a
---    cancelled job never calls back and closes its coroutine.
--- 4. Observable cost: completion logs the slice count and the longest slice,
---    the number that decides whether the run loop was blocked.
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "infra.paced_job"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Default work budget of one slice, in milliseconds.
M.DEFAULT_SLICE_MS = 12

--- Default idle gap between two slices, in seconds. It leaves the run loop a
--- turn for input, timers and WebKit commits.
M.DEFAULT_GAP_SEC = 0.01





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- Reads the monotonic clock in milliseconds.
--- @return number milliseconds
local function now_ms()
	return hs.timer.absoluteTime() / 1000000
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Starts one paced job.
--- @param opts table { label = string, body = function(pacer): any,
---   on_done = function(ok: boolean, result_or_error: any),
---   slice_ms = number|nil, gap_sec = number|nil }.
--- @return table|nil job Handle exposing `cancel()`, `state` and counters.
--- @return string|nil err Refusal reason when the job could not be armed.
function M.start(opts)
	if type(opts) ~= "table" or type(opts.label) ~= "string" or opts.label == ""
		or type(opts.body) ~= "function" or type(opts.on_done) ~= "function" then
		error("PacedJob.start requires label, body and on_done", 2)
	end
	local slice_ms = opts.slice_ms or M.DEFAULT_SLICE_MS
	local gap_sec  = opts.gap_sec or M.DEFAULT_GAP_SEC
	if type(slice_ms) ~= "number" or slice_ms <= 0 or type(gap_sec) ~= "number" or gap_sec < 0 then
		error("PacedJob.start requires a positive slice budget and a non-negative gap", 2)
	end

	local job = { label = opts.label, state = "scheduled", slices = 0, max_slice_ms = 0 }
	local slice_started = 0
	local started_at = now_ms()
	local co

	local pacer = {}
	--- Yields the job once the current slice has spent its budget.
	function pacer.pause()
		if coroutine.running() ~= co then
			error("pacer.pause() called outside its own job", 2)
		end
		if now_ms() - slice_started >= slice_ms then coroutine.yield() end
	end

	co = coroutine.create(function() return opts.body(pacer) end)

	local function settle(ok, result)
		if job.state ~= "running" then return end
		job.state = ok and "done" or "failed"
		if ok then
			Logger.success(LOG, "%s completed in %d slice(s), longest %.1f ms, %.0f ms wall.",
				job.label, job.slices, job.max_slice_ms, now_ms() - started_at)
		else
			Logger.error(LOG, "%s failed after %d slice(s): %s.", job.label, job.slices, tostring(result))
		end
		opts.on_done(ok, result)
	end

	local schedule
	local function step()
		job.timer = nil
		if job.state ~= "scheduled" and job.state ~= "running" then return end
		job.state = "running"
		job.slices = job.slices + 1
		slice_started = now_ms()
		local ok, result = coroutine.resume(co)
		local elapsed = now_ms() - slice_started
		if elapsed > job.max_slice_ms then job.max_slice_ms = elapsed end
		if job.state ~= "running" then return end
		if not ok then
			settle(false, debug.traceback(co, tostring(result)))
		elseif coroutine.status(co) == "dead" then
			settle(true, result)
		else
			schedule()
		end
	end

	schedule = function()
		local armed, handle, committed = xpcall(function()
			return TimerScheduler.after(gap_sec, step)
		end, debug.traceback)
		if armed and type(handle) == "table" and committed == true then
			job.timer = handle
			return true
		end
		if armed and type(handle) == "table" then pcall(TimerScheduler.cancel, handle) end
		local reason = "slice timer refused: " .. tostring(armed and committed or handle)
		if job.state == "running" then
			settle(false, reason)
		else
			job.state = "failed"
			Logger.error(LOG, "%s could not start: %s.", job.label, reason)
		end
		return false
	end

	--- Cancels the job; a cancelled job never calls `on_done`.
	--- @return boolean settled True once no timer remains owned.
	function job.cancel()
		if job.state == "done" or job.state == "failed" or job.state == "cancelled" then return true end
		job.state = "cancelled"
		local settled = true
		if job.timer then
			local ok, stopped = pcall(TimerScheduler.cancel, job.timer)
			settled = ok and stopped == true
			if settled then job.timer = nil end
		end
		if coroutine.status(co) == "suspended" then pcall(coroutine.close, co) end
		Logger.info(LOG, "%s cancelled after %d slice(s).", job.label, job.slices)
		return settled
	end

	Logger.start(LOG, "%s scheduled (slice budget %d ms).", job.label, slice_ms)
	if not schedule() then return nil, "slice timer refused" end
	return job
end

return M
