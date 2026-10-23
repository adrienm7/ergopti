--- infra/phase_stats.lua

--- ==============================================================================
--- MODULE: Phase Stats
--- DESCRIPTION:
--- Permanent, privacy-safe timing and counting for every phase that can hide
--- latency: per-key hot path stages, menu build items, boot sub-stages, config
--- parses, child processes. Each phase keeps only an occurrence count, a total
--- and a maximum in preallocated tables, so recording costs one clock read and
--- three table updates and never builds a string. A periodic flush turns the
--- counters into ONE evidence line per phase family, then clears them.
---
--- FEATURES & RATIONALE:
--- 1. Near-zero cost: record() allocates nothing after a phase's first use; the
---    flush formats text only when INFO is enabled, so a quiet log level pays
---    for counters and nothing else.
--- 2. Closed names only: phase names are source constants (menu item ids, stage
---    names). No typed text, path or URL ever enters a phase name or a value.
--- 3. Hold attribution: a phase that lasts RING_MIN_MS or more is also written
---    to a small ring so the slow-callback report can name the phases that ran
---    during the held window (recent_since).
--- 4. One owner for the interval: start()/stop() pair the flush timer and
---    reject a second start, like every stateful module.
--- ==============================================================================

local M = {}

local LOG = "phase_stats"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

M.DEFAULT_INTERVAL_SEC = 300

-- Phases at least this long also enter the attribution ring.
local RING_MIN_NS = 2 * 1e6
local RING_SIZE   = 32
local NS_PER_MS   = 1e6
-- A family line lists at most this many phases, busiest first by total time.
local MAX_PHASES_PER_LINE = 24
-- The slow-callback report names at most this many phases.
local MAX_ATTRIBUTED = 5





-- ===============================
-- ===============================
-- ======= 2/ Module State =======
-- ===============================
-- ===============================

-- _phases[name] = { n = count, total = ns, max = ns }
local _phases   = {}
-- _counters[name] = integer
local _counters = {}
local _ring_name, _ring_end, _ring_dur = {}, {}, {}
local _ring_head = 0
local _handle = nil
-- Clock override for tests; nil reads the native monotonic clock.
local _clock = nil





-- ============================
-- ============================
-- ======= 3/ Recording =======
-- ============================
-- ============================

--- Reads the monotonic clock in nanoseconds.
--- @return number
function M.now()
	if _clock then return _clock() end
	local native = rawget(_G, "hs")
	local absolute = type(native) == "table" and type(native.timer) == "table"
		and native.timer.absoluteTime or nil
	if absolute then return absolute() end
	return os.clock() * 1e9
end

--- Replaces the clock (tests only). Pass nil to restore the native clock.
--- @param fn function|nil Zero-argument function returning nanoseconds.
function M.use_clock(fn)
	_clock = fn
end

--- Adds one occurrence of `name` that lasted `elapsed_ns`.
--- @param name string Closed phase name, `family.phase`.
--- @param elapsed_ns number Duration in nanoseconds.
function M.add(name, elapsed_ns)
	local phase = _phases[name]
	if phase == nil then
		phase = { n = 0, total = 0, max = 0 }
		_phases[name] = phase
	end
	phase.n = phase.n + 1
	phase.total = phase.total + elapsed_ns
	if elapsed_ns > phase.max then phase.max = elapsed_ns end
	if elapsed_ns >= RING_MIN_NS then
		_ring_head = _ring_head % RING_SIZE + 1
		_ring_name[_ring_head] = name
		_ring_end[_ring_head] = M.now()
		_ring_dur[_ring_head] = elapsed_ns
	end
end

--- Closes a phase opened with M.now().
--- @param name string Closed phase name.
--- @param start_ns number Timestamp from M.now().
--- @return number elapsed_ms Duration in milliseconds.
function M.stop(name, start_ns)
	local elapsed = M.now() - start_ns
	M.add(name, elapsed)
	return elapsed / NS_PER_MS
end

--- Adds `amount` (default 1) to a plain event counter.
--- @param name string Closed counter name, `family.counter`.
--- @param amount number|nil Increment.
function M.count(name, amount)
	_counters[name] = (_counters[name] or 0) + (amount or 1)
end

--- Returns the live figures of a phase, for tests and diagnostics.
--- @param name string Phase name.
--- @return table|nil figures { n, total_ms, max_ms }, nil when never recorded.
function M.figures(name)
	local phase = _phases[name]
	if phase == nil then return nil end
	return { n = phase.n, total_ms = phase.total / NS_PER_MS, max_ms = phase.max / NS_PER_MS }
end

--- Returns a counter's value.
--- @param name string Counter name.
--- @return number
function M.counter(name)
	return _counters[name] or 0
end

--- Names the long phases that ended at or after `since_ns`, longest first.
--- Used by the slow-callback report to attribute a main-thread hold.
--- @param since_ns number Timestamp from M.now() when the held callback began.
--- @return string|nil list `name=12.3 ms, name=4.1 ms`, nil when none ran.
function M.recent_since(since_ns)
	local found = {}
	for slot = 1, RING_SIZE do
		if _ring_name[slot] ~= nil and _ring_end[slot] >= since_ns then
			found[#found + 1] = { name = _ring_name[slot], dur = _ring_dur[slot] }
		end
	end
	if #found == 0 then return nil end
	table.sort(found, function(a, b) return a.dur > b.dur end)
	local parts = {}
	for index = 1, math.min(#found, MAX_ATTRIBUTED) do
		parts[index] = string.format("%s=%.1f ms", found[index].name, found[index].dur / NS_PER_MS)
	end
	return table.concat(parts, ", ")
end

--- Clears every phase, counter and ring entry.
function M.reset()
	_phases, _counters = {}, {}
	_ring_name, _ring_end, _ring_dur = {}, {}, {}
	_ring_head = 0
end





-- ========================
-- ========================
-- ======= 4/ Flush =======
-- ========================
-- ========================

--- Returns the family of a phase name: the text before its first dot.
--- @param name string
--- @return string
local function family_of(name)
	return name:match("^([^.]+)%.") or "misc"
end

--- Emits one evidence line per family plus a memory line, then clears the
--- counters. Text is formatted only when INFO is enabled.
--- @param interval_sec number|nil Seconds the counters cover, shown in the line.
--- @return integer lines Evidence lines emitted.
function M.flush(interval_sec)
	local Logger = require("infra.logger")
	local phases, counters = _phases, _counters
	M.reset()
	if not Logger.is_enabled(Logger.LEVELS.INFO) then return 0 end

	local families, order = {}, {}
	local function family(name)
		local key = family_of(name)
		if families[key] == nil then
			families[key] = { phases = {}, counters = {} }
			order[#order + 1] = key
		end
		return families[key]
	end
	for name, phase in pairs(phases) do
		local entry = family(name)
		entry.phases[#entry.phases + 1] = { name = name, phase = phase }
	end
	for name, value in pairs(counters) do
		local entry = family(name)
		entry.counters[#entry.counters + 1] = { name = name, value = value }
	end
	table.sort(order)

	local lines = 0
	for _, key in ipairs(order) do
		local entry = families[key]
		table.sort(entry.phases, function(a, b) return a.phase.total > b.phase.total end)
		table.sort(entry.counters, function(a, b) return a.name < b.name end)
		local parts = {}
		for index = 1, math.min(#entry.phases, MAX_PHASES_PER_LINE) do
			local item = entry.phases[index]
			parts[#parts + 1] = string.format("%s n=%d mean=%.2f max=%.2f total=%.1f ms",
				item.name:sub(#key + 2), item.phase.n, item.phase.total / item.phase.n / NS_PER_MS,
				item.phase.max / NS_PER_MS, item.phase.total / NS_PER_MS)
		end
		for _, item in ipairs(entry.counters) do
			parts[#parts + 1] = string.format("#%s=%d", item.name:sub(#key + 2), item.value)
		end
		Logger.evidence(LOG, "Phase summary [%s] over %d s: %s.", key,
			math.floor(interval_sec or M.DEFAULT_INTERVAL_SEC), table.concat(parts, " | "))
		lines = lines + 1
	end
	Logger.evidence(LOG, "Memory snapshot: lua=%d KB.", math.floor(collectgarbage("count")))
	return lines + 1
end





-- ============================
-- ============================
-- ======= 5/ Lifecycle =======
-- ============================
-- ============================

--- Starts the periodic flush. A second start is refused.
--- @param interval_sec number|nil Flush interval in seconds.
--- @return boolean started
function M.start(interval_sec)
	local Logger = require("infra.logger")
	if _handle ~= nil then
		Logger.error(LOG, "Phase summary timer is already running; a second start is refused.")
		return false
	end
	local interval = interval_sec or M.DEFAULT_INTERVAL_SEC
	Logger.start(LOG, "Starting the phase summary timer (every %d s)…", interval)
	local handle, committed = require("adapters.timer_scheduler").every(interval, function()
		M.flush(interval)
	end)
	if committed ~= true then
		Logger.error(LOG, "The phase summary timer was not armed.")
		return false
	end
	_handle = handle
	Logger.done(LOG, "Phase summary timer armed.")
	return true
end

--- Stops the periodic flush, emitting the last interval first.
--- @return boolean stopped
function M.stop_reporting()
	if _handle == nil then return true end
	local Logger = require("infra.logger")
	Logger.start(LOG, "Stopping the phase summary timer…")
	M.flush()
	local settled = require("adapters.timer_scheduler").cancel(_handle)
	if settled ~= true then
		Logger.error(LOG, "The phase summary timer could not be stopped.")
		return false
	end
	_handle = nil
	Logger.done(LOG, "Phase summary timer stopped.")
	return true
end

return M
