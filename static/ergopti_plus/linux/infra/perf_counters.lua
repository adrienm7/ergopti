--- infra/perf_counters.lua

--- ==============================================================================
--- MODULE: Performance Counters (Linux)
--- DESCRIPTION:
--- Permanent, privacy-safe timing and count instrumentation for the daemon's
--- hot paths: the event loop, the key pump, the tap-hold engine, the output
--- writers, the keystats writer and the tray. Counters aggregate in memory and
--- one evidence line per interval reports them, so the cost stays flat however
--- fast the user types. A span that belongs to the shared hot-path inventory
--- (_shared/lua/hotpath_segments.lua) is also reported at WARNING the moment it
--- exceeds its threshold, the Linux counterpart of the Windows HotPath and the
--- macOS hotpath_profiler.
---
--- FEATURES & RATIONALE:
--- 1. Closed enum. Every counter and span is declared below; an unknown name
---    raises. A summary therefore carries names and numbers only, never typed
---    text, window titles or paths, and a typo cannot silently open a new bucket.
--- 2. Counting and timing are always on. A counter costs one table increment and
---    a span two reads of the monotonic clock (luv.hrtime) plus a few table
---    updates; no string is built unless the span is slow. Timing used to be
---    gated on DEBUG, which left a production log with no latency evidence at
---    all and made a stall report impossible to attribute afterwards.
--- 3. Slow segments are named, not typed: the WARNING carries the span name and
---    the duration, never text, a window title or a path.
--- 4. One summary per interval through Logger.evidence, which the logger never
---    collapses, with the Lua heap size as the memory snapshot. Per-interval
---    values reset; lifetime totals stay available through snapshot().
--- 5. Explicit ownership: the event loop's periodic tick drives
---    maybe_flush(); nothing here owns a timer.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Monotonic = require("infra.monotonic")
local Segments  = require("hotpath_segments")

local LOG = "PerfCounters"
-- Tag of the slow-segment WARNING, shared with the Windows and macOS drivers so
-- one search finds the line on every OS.
local HOTPATH_LOG = "HotPath"

-- Milliseconds between two summary lines.
M.FLUSH_INTERVAL_MS = 60000

-- Every counter, by name. A name is "<area>.<what>".
local COUNTER_NAMES = {
	"loop.idle_ticks", "loop.idle_wakes_input", "loop.idle_timeouts",
	"loop.periodic_ticks", "loop.deferred_runs",
	"input.pump_calls", "input.events", "input.key_events", "input.pointer_events",
	"input.forwarded_events",
	"taphold.processed", "taphold.ticks",
	"output.uinput_writes", "output.uinput_events", "shell.spawns",
	"hotstring.matches", "hotstring.expansions",
	"keystats.ingests", "keystats.flushes",
	"tray.builds", "tray.opens",
}

-- Every span (a duration with its count, total and maximum), by name.
local SPAN_NAMES = {
	"loop.idle", "loop.periodic",
	"input.dispatch", "input.char", "taphold.process",
	"output.uinput_write",
	"hotstring.match", "hotstring.expand",
	"keystats.ingest", "keystats.flush",
	"tray.build", "tray.open",
}

local _counts, _totals = {}, {}                 -- name -> interval / lifetime count
local _span_n, _span_sum, _span_max = {}, {}, {} -- name -> interval figures
local _life_n, _life_sum, _life_max = {}, {}, {} -- name -> lifetime figures
local _span_slow, _life_slow = {}, {}            -- name -> slow occurrences
local _interval_start_ms = nil

-- Slow threshold in milliseconds of each span that is a declared Linux segment.
-- A span absent here (an idle wait, a tray build) is timed but never a warning:
-- an idle wait is long by design. Built at the first closed span, not at require:
-- shell_runner loads this module, and loading it must not parse the timings file.
local _slow_ms = nil

--- The per-segment slow thresholds, read once from the shared timings registry.
--- @return table name -> milliseconds
local function slow_limits()
	if _slow_ms then return _slow_ms end
	local default_ms = require("infra.timings").ms("logger", "hotpath_slow_ms")
	local limits = {}
	for name in pairs(Segments.for_driver("linux")) do limits[name] = Segments.threshold_ms(name, default_ms) end
	_slow_ms = limits
	return limits
end
-- Rate limiter of the WARNING (window shared with macOS); the slow counts stay exact.
local _admit_slow = Segments.new_slow_gate()

local function reset_state()
	_counts, _totals = {}, {}
	_span_n, _span_sum, _span_max = {}, {}, {}
	_life_n, _life_sum, _life_max = {}, {}, {}
	_span_slow, _life_slow = {}, {}
	_admit_slow = Segments.new_slow_gate()
	for _, name in ipairs(COUNTER_NAMES) do _counts[name] = 0; _totals[name] = 0 end
	for _, name in ipairs(SPAN_NAMES) do
		_span_n[name], _span_sum[name], _span_max[name] = 0, 0, 0
		_life_n[name], _life_sum[name], _life_max[name] = 0, 0, 0
		_span_slow[name], _life_slow[name] = 0, 0
	end
	_interval_start_ms = nil
end
reset_state()

--- Adds to a counter.
--- @param name string A declared counter.
--- @param amount number|nil Defaults to 1.
function M.count(name, amount)
	local current = _counts[name]
	if current == nil then error("unknown perf counter '" .. tostring(name) .. "'", 2) end
	_counts[name] = current + (amount or 1)
end

--- A start stamp for span().
--- @return number Monotonic milliseconds.
function M.clock()
	return Monotonic.now_ms()
end

--- Closes a span opened with clock(). A declared hot-path segment slower than
--- its threshold also logs one WARNING (name and duration only).
--- @param name string A declared span.
--- @param started number The stamp clock() returned.
--- @return number elapsed_ms The measured duration.
function M.span(name, started)
	local n = _span_n[name]
	if n == nil then error("unknown perf span '" .. tostring(name) .. "'", 2) end
	if type(started) ~= "number" then error("perf span '" .. name .. "' closed without a clock() stamp", 2) end
	local now = Monotonic.now_ms()
	local elapsed = now - started
	_span_n[name] = n + 1
	_span_sum[name] = _span_sum[name] + elapsed
	if elapsed > _span_max[name] then _span_max[name] = elapsed end
	local limit = slow_limits()[name]
	if limit ~= nil and elapsed > limit then
		_span_slow[name] = _span_slow[name] + 1
		local admitted, skipped = _admit_slow(name, now)
		if admitted then
			Logger.warn(HOTPATH_LOG, "Slow %s: %.2f ms (%d similar since the last line).", name, elapsed, skipped)
		end
	end
	return elapsed
end

--- The figures since the daemon started, for diagnostics and tests.
--- @return table { counts = {name=n}, spans = {name={n,sum_ms,max_ms,slow}} }
function M.snapshot()
	local counts, spans = {}, {}
	for _, name in ipairs(COUNTER_NAMES) do counts[name] = _totals[name] + _counts[name] end
	for _, name in ipairs(SPAN_NAMES) do
		spans[name] = {
			n = _life_n[name] + _span_n[name],
			sum_ms = _life_sum[name] + _span_sum[name],
			max_ms = math.max(_life_max[name], _span_max[name]),
			slow = _life_slow[name] + _span_slow[name],
		}
	end
	return { counts = counts, spans = spans }
end

--- Builds the summary text of the current interval: nonzero figures only.
--- @return string
local function interval_text(heap_kb, seconds)
	local parts = { string.format("window=%.0fs heap=%dKB", seconds, heap_kb) }
	for _, name in ipairs(COUNTER_NAMES) do
		if _counts[name] ~= 0 then parts[#parts + 1] = string.format("%s=%d", name, _counts[name]) end
	end
	for _, name in ipairs(SPAN_NAMES) do
		if _span_n[name] ~= 0 then
			parts[#parts + 1] = string.format("%s=%d/%.2f/%.2fms", name,
				_span_n[name], _span_sum[name], _span_max[name])
			if _span_slow[name] ~= 0 then
				parts[#parts + 1] = string.format("%s.slow=%d", name, _span_slow[name])
			end
		end
	end
	return table.concat(parts, " ")
end

--- Emits the interval summary and starts the next interval.
--- @param now_ms number
local function flush(now_ms)
	local seconds = (now_ms - _interval_start_ms) / 1000
	Logger.evidence(LOG, "Interval (counts; spans as n/total/max): %s | log: %s",
		interval_text(math.floor(collectgarbage("count")), seconds),
		Logger.volume_text(Logger.volume_interval()))
	for _, name in ipairs(COUNTER_NAMES) do
		_totals[name] = _totals[name] + _counts[name]
		_counts[name] = 0
	end
	for _, name in ipairs(SPAN_NAMES) do
		_life_slow[name] = _life_slow[name] + _span_slow[name]
		_span_slow[name] = 0
		_life_n[name] = _life_n[name] + _span_n[name]
		_life_sum[name] = _life_sum[name] + _span_sum[name]
		if _span_max[name] > _life_max[name] then _life_max[name] = _span_max[name] end
		_span_n[name], _span_sum[name], _span_max[name] = 0, 0, 0
	end
	_interval_start_ms = now_ms
end

--- Called from the event loop's periodic tick: emits the summary when an
--- interval has elapsed.
--- @param now_ms number|nil Monotonic ms; read when absent.
--- @return boolean flushed
function M.maybe_flush(now_ms)
	now_ms = now_ms or Monotonic.now_ms()
	if _interval_start_ms == nil then
		_interval_start_ms = now_ms
		return false
	end
	if now_ms - _interval_start_ms < M.FLUSH_INTERVAL_MS then return false end
	flush(now_ms)
	return true
end

--- Emits the pending interval now (shutdown).
function M.flush_now()
	local now_ms = Monotonic.now_ms()
	if _interval_start_ms == nil then _interval_start_ms = now_ms end
	flush(now_ms)
end

--- Resets every figure. Tests only.
function M._reset_for_test()
	reset_state()
end

return M
