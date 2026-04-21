--- lib/perf.lua

--- ==============================================================================
--- MODULE: Perf
--- DESCRIPTION:
--- Lightweight latency-measurement helper: each named bucket keeps a fixed-size
--- ring buffer of sample durations, from which count / mean / p50 / p99 / max
--- can be computed on demand. Designed to cost nothing when disabled so it can
--- live permanently in hot paths without degrading steady-state performance.
---
--- FEATURES & RATIONALE:
--- 1. Opt-in Sampling: set_enabled(false) makes sample() a single table read +
---    early return, so instrumentation on per-keystroke code does not regress
---    latency when the user is not actively measuring.
--- 2. Bounded Memory: each bucket retains at most MAX_SAMPLES durations in a
---    ring buffer, so long measurement sessions never grow unboundedly.
--- 3. Nanosecond Resolution: samples are stored in ns (hs.timer.absoluteTime)
---    so sub-microsecond detail is preserved; reports round to µs for humans.
--- 4. No Dependency on Logger: callers pass a logger function to report_all()
---    so this module can be required from libs that predate the logger setup.
--- ==============================================================================

local hs = hs
local M  = {}




-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- Maximum samples kept per bucket. A ring buffer drops the oldest sample when
-- it overflows, so long-running sessions still reflect recent behaviour rather
-- than being dominated by startup outliers.
local MAX_SAMPLES = 500




-- ===============================
-- ===============================
-- ======= 2/ Module State =======
-- ===============================
-- ===============================

local _enabled = false
-- _buckets[name] = { n = used_count, head = next_write_index, data = array }.
-- head wraps around MAX_SAMPLES so the writer never allocates after steady state.
local _buckets = {}




-- ===================================
-- ===================================
-- ======= 3/ Enable / Disable =======
-- ===================================
-- ===================================

--- Enables sample recording. When disabled, sample() returns immediately.
--- @param v boolean
function M.set_enabled(v)
	_enabled = (v == true)
end

--- Returns true when samples are being recorded.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Returns a nanosecond timestamp suitable for use as the start time of a
--- sample(). Falls back to secondsSinceEpoch when absoluteTime is unavailable.
--- @return number Timestamp in nanoseconds.
function M.now()
	if hs and hs.timer and hs.timer.absoluteTime then
		return hs.timer.absoluteTime()
	end
	return (hs.timer.secondsSinceEpoch() or 0) * 1e9
end




-- ===========================
-- ===========================
-- ======= 4/ Sampling =======
-- ===========================
-- ===========================

--- Records the elapsed time between `t0` and the current moment in the bucket
--- named `name`. When sampling is disabled the call returns in a handful of
--- cycles without allocating.
--- @param name string Bucket identifier.
--- @param t0 number Start timestamp in nanoseconds (from M.now()).
function M.sample(name, t0)
	if not _enabled then return end
	local t1 = M.now()
	local dt = t1 - t0

	local b = _buckets[name]
	if not b then
		b = { n = 0, head = 1, data = {} }
		_buckets[name] = b
	end

	b.data[b.head] = dt
	b.head         = (b.head % MAX_SAMPLES) + 1
	if b.n < MAX_SAMPLES then b.n = b.n + 1 end
end




-- ============================
-- ============================
-- ======= 5/ Reporting =======
-- ============================
-- ============================

--- Returns aggregate statistics for `name`, or nil when the bucket is empty.
--- @param name string Bucket identifier.
--- @return table|nil { count, mean_us, p50_us, p99_us, max_us, total_ms }.
function M.report(name)
	local b = _buckets[name]
	if not b or b.n == 0 then return nil end

	-- Copy into a local array and sort to compute percentiles. We recopy every
	-- call so the ring buffer's underlying array stays unchanged.
	local sorted = {}
	local total  = 0
	for i = 1, b.n do
		local v = b.data[i]
		sorted[i] = v
		total     = total + v
	end
	table.sort(sorted)

	local p50_idx = math.max(1, math.ceil(b.n * 0.50))
	local p99_idx = math.max(1, math.ceil(b.n * 0.99))

	return {
		count    = b.n,
		mean_us  = (total / b.n) / 1000,
		p50_us   = sorted[p50_idx] / 1000,
		p99_us   = sorted[p99_idx] / 1000,
		max_us   = sorted[b.n] / 1000,
		total_ms = total / 1e6,
	}
end

--- Emits one log line per populated bucket via the supplied logger callback.
--- The callback is expected to accept (tag, fmt, ...) arguments — typically
--- Logger.info from lib.logger. Passing the callback in explicitly keeps this
--- module free of any require-time dependency on the logger module.
--- @param logger function Callback with signature fn(tag, fmt, ...).
function M.report_all(logger)
	if type(logger) ~= "function" then return end
	for name, _ in pairs(_buckets) do
		local r = M.report(name)
		if r then
			logger("perf",
				"[%s] n=%d  mean=%.1fµs  p50=%.1fµs  p99=%.1fµs  max=%.1fµs  total=%.2fms",
				name, r.count, r.mean_us, r.p50_us, r.p99_us, r.max_us, r.total_ms)
		end
	end
end

--- Clears the samples for `name`, or every bucket when `name` is nil.
--- @param name string|nil Bucket identifier, or nil to wipe all.
function M.reset(name)
	if name == nil then
		_buckets = {}
	else
		_buckets[name] = nil
	end
end

return M
