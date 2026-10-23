--- infra/perf_counters.lua

--- ==============================================================================
--- MODULE: Performance Counters (Linux)
--- DESCRIPTION:
--- Permanent, privacy-safe timing and count instrumentation for the daemon's
--- hot paths: the event loop, the key pump, the tap-hold engine, the output
--- writers, the keystats writer and the tray. Counters aggregate in memory and
--- one evidence line per interval reports them, so the cost stays flat however
--- fast the user types.
---
--- FEATURES & RATIONALE:
--- 1. Closed enum. Every counter and span is declared below; an unknown name
---    raises. A summary therefore carries names and numbers only, never typed
---    text, window titles or paths, and a typo cannot silently open a new bucket.
--- 2. Counting is always on and costs one table increment. Timing reads the
---    clock only while the logger admits DEBUG (clock() returns nil otherwise),
---    so a production run pays one boolean test per measured span.
--- 3. One summary per interval through Logger.evidence, which the logger never
---    collapses, with the Lua heap size as the memory snapshot. Per-interval
---    values reset; lifetime totals stay available through snapshot().
--- 4. Explicit ownership: the event loop's periodic tick drives
---    maybe_flush(); nothing here owns a timer.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Monotonic = require("infra.monotonic")

local LOG = "PerfCounters"

-- Milliseconds between two summary lines.
M.FLUSH_INTERVAL_MS = 60000

-- The logger level at or below which spans are timed (Logger.LEVELS.DEBUG).
local TIMING_LEVEL = 10

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
	"input.dispatch", "taphold.process",
	"output.uinput_write",
	"hotstring.match", "hotstring.expand",
	"keystats.ingest", "keystats.flush",
	"tray.build", "tray.open",
}

local _counts, _totals = {}, {}                 -- name -> interval / lifetime count
local _span_n, _span_sum, _span_max = {}, {}, {} -- name -> interval figures
local _life_n, _life_sum, _life_max = {}, {}, {} -- name -> lifetime figures

-- True while spans are timed; refreshed by refresh_timing() at each flush check.
local _timing = false
local _interval_start_ms = nil

local function reset_state()
	_counts, _totals = {}, {}
	_span_n, _span_sum, _span_max = {}, {}, {}
	_life_n, _life_sum, _life_max = {}, {}, {}
	for _, name in ipairs(COUNTER_NAMES) do _counts[name] = 0; _totals[name] = 0 end
	for _, name in ipairs(SPAN_NAMES) do
		_span_n[name], _span_sum[name], _span_max[name] = 0, 0, 0
		_life_n[name], _life_sum[name], _life_max[name] = 0, 0, 0
	end
	_timing = false
	_interval_start_ms = nil
end
reset_state()

--- Re-reads the logger level; timing is on while DEBUG is admitted.
function M.refresh_timing()
	local level = type(Logger.get_level) == "function" and Logger.get_level() or nil
	_timing = type(level) == "number" and level <= TIMING_LEVEL
	return _timing
end

--- Whether spans are being timed now.
--- @return boolean
function M.timing_enabled()
	return _timing
end

--- Adds to a counter.
--- @param name string A declared counter.
--- @param amount number|nil Defaults to 1.
function M.count(name, amount)
	local current = _counts[name]
	if current == nil then error("unknown perf counter '" .. tostring(name) .. "'", 2) end
	_counts[name] = current + (amount or 1)
end

--- A start stamp for span(), nil while timing is off.
--- @return number|nil
function M.clock()
	if not _timing then return nil end
	return Monotonic.now_ms()
end

--- Closes a span opened with clock(); a nil stamp (timing off) is a no-op.
--- @param name string A declared span.
--- @param started number|nil The stamp clock() returned.
function M.span(name, started)
	if started == nil then return end
	local n = _span_n[name]
	if n == nil then error("unknown perf span '" .. tostring(name) .. "'", 2) end
	local elapsed = Monotonic.now_ms() - started
	_span_n[name] = n + 1
	_span_sum[name] = _span_sum[name] + elapsed
	if elapsed > _span_max[name] then _span_max[name] = elapsed end
end

--- The figures since the daemon started, for diagnostics and tests.
--- @return table { counts = {name=n}, spans = {name={n,sum_ms,max_ms}} }
function M.snapshot()
	local counts, spans = {}, {}
	for _, name in ipairs(COUNTER_NAMES) do counts[name] = _totals[name] + _counts[name] end
	for _, name in ipairs(SPAN_NAMES) do
		spans[name] = {
			n = _life_n[name] + _span_n[name],
			sum_ms = _life_sum[name] + _span_sum[name],
			max_ms = math.max(_life_max[name], _span_max[name]),
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
		end
	end
	return table.concat(parts, " ")
end

--- Emits the interval summary and starts the next interval.
--- @param now_ms number
local function flush(now_ms)
	local seconds = (now_ms - _interval_start_ms) / 1000
	Logger.evidence(LOG, "Interval (counts; spans as n/total/max): %s",
		interval_text(math.floor(collectgarbage("count")), seconds))
	for _, name in ipairs(COUNTER_NAMES) do
		_totals[name] = _totals[name] + _counts[name]
		_counts[name] = 0
	end
	for _, name in ipairs(SPAN_NAMES) do
		_life_n[name] = _life_n[name] + _span_n[name]
		_life_sum[name] = _life_sum[name] + _span_sum[name]
		if _span_max[name] > _life_max[name] then _life_max[name] = _span_max[name] end
		_span_n[name], _span_sum[name], _span_max[name] = 0, 0, 0
	end
	_interval_start_ms = now_ms
end

--- Called from the event loop's periodic tick: refreshes the timing switch and
--- emits the summary when an interval has elapsed.
--- @param now_ms number|nil Monotonic ms; read when absent.
--- @return boolean flushed
function M.maybe_flush(now_ms)
	M.refresh_timing()
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
