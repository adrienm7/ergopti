--- _shared/lua/phase_stats_core.lua

--- ==============================================================================
--- MODULE: Phase Stats Core (Lua drivers)
--- DESCRIPTION:
--- Permanent, privacy-safe timing and counting for every phase that can hide
--- latency: per-key hot path stages, menu build items, boot sub-stages, config
--- parses, child processes. Each phase keeps only an occurrence count, a total
--- and a maximum in preallocated tables, so recording costs one clock read and
--- three table updates and never builds a string. A flush turns the counters
--- into ONE evidence line per phase family, then clears them.
---
--- FEATURES & RATIONALE:
--- 1. One implementation for macOS and Linux. The macOS module owned this code
---    alone; Linux needs the same phases (process.*, boot.*), and two copies of
---    the bookkeeping would drift. A driver supplies only what differs: its
---    monotonic nanosecond clock, its evidence logger and its flush cadence.
--- 2. Near-zero cost: add() allocates nothing after a phase's first use; the
---    flush formats text only when INFO is enabled, so a quiet log level pays
---    for counters and nothing else.
--- 3. Closed names only: phase names are source constants (menu item ids, stage
---    names, program names). No typed text, path or URL ever enters a phase name
---    or a value.
--- 4. Hold attribution: a phase that lasts RING_MIN_NS or more is also written
---    to a small ring so a slow-callback report can name the phases that ran
---    during the held window (recent_since).
--- 5. Explicit ownership: new() is called once per driver module; each instance
---    owns its tables, so a test builds its own and shares nothing.
--- ==============================================================================

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

M.DEFAULT_FLUSH_SECONDS = 300

-- Phases at least this long also enter the attribution ring. The ring holds
-- the last slow phases a held callback can name, not keystrokes.
local RING_MIN_NS           = 2 * 1e6
local ATTRIBUTION_RING_SIZE = 32
local NANOSECONDS_PER_MILLISECOND = 1e6
-- A family line lists at most this many phases, busiest first by total time.
local MAX_PHASES_PER_LINE   = 24
-- The slow-callback report names at most this many phases.
local MAX_ATTRIBUTED        = 5





-- ===========================
-- ===========================
-- ======= 2/ Instance =======
-- ===========================
-- ===========================

--- Returns the family of a phase name: the text before its first dot.
--- @param name string
--- @return string
local function family_of(name)
	return name:match("^([^.]+)%.") or "misc"
end

--- Creates one driver's phase statistics.
--- @param options table { now_ns = function() -> monotonic nanoseconds,
---   info_enabled = function() -> boolean, evidence = function(fmt, ...) that
---   writes one never-collapsed record under the driver's own module tag }.
--- @return table stats The instance API.
function M.new(options)
	assert(type(options) == "table", "phase stats: options must be a table")
	for _, key in ipairs({ "now_ns", "info_enabled", "evidence" }) do
		assert(type(options[key]) == "function", "phase stats: option " .. key .. " must be a function")
	end
	local default_now, info_enabled, evidence = options.now_ns, options.info_enabled, options.evidence

	local S = { DEFAULT_INTERVAL_SEC = M.DEFAULT_FLUSH_SECONDS }
	-- _phases[name] = { n = count, total = ns, max = ns }
	local _phases, _counters = {}, {}
	local _ring_name, _ring_end, _ring_dur = {}, {}, {}
	local _ring_head = 0
	-- Clock override for tests; nil reads the driver's monotonic clock.
	local _clock = nil

	--- Reads the monotonic clock in nanoseconds.
	--- @return number
	function S.now()
		if _clock then return _clock() end
		return default_now()
	end

	--- Replaces the clock (tests only). Pass nil to restore the driver clock.
	--- @param fn function|nil Zero-argument function returning nanoseconds.
	function S.use_clock(fn)
		_clock = fn
	end

	--- Adds one occurrence of `name` that lasted `elapsed_ns`.
	--- @param name string Closed phase name, `family.phase`.
	--- @param elapsed_ns number Duration in nanoseconds.
	function S.add(name, elapsed_ns)
		local phase = _phases[name]
		if phase == nil then
			phase = { n = 0, total = 0, max = 0 }
			_phases[name] = phase
		end
		phase.n = phase.n + 1
		phase.total = phase.total + elapsed_ns
		if elapsed_ns > phase.max then phase.max = elapsed_ns end
		if elapsed_ns >= RING_MIN_NS then
			_ring_head = _ring_head % ATTRIBUTION_RING_SIZE + 1
			_ring_name[_ring_head] = name
			_ring_end[_ring_head] = S.now()
			_ring_dur[_ring_head] = elapsed_ns
		end
	end

	--- Adds one occurrence of `name` that lasted `elapsed_ms`, for callers that
	--- already measured milliseconds (a child process, a menu rebuild).
	--- @param name string Closed phase name, `family.phase`.
	--- @param elapsed_ms number Duration in milliseconds.
	function S.add_ms(name, elapsed_ms)
		S.add(name, (tonumber(elapsed_ms) or 0) * NANOSECONDS_PER_MILLISECOND)
	end

	--- Closes a phase opened with S.now().
	--- @param name string Closed phase name.
	--- @param start_ns number Timestamp from S.now().
	--- @return number elapsed_ms Duration in milliseconds.
	function S.stop(name, start_ns)
		local elapsed = S.now() - start_ns
		S.add(name, elapsed)
		return elapsed / NANOSECONDS_PER_MILLISECOND
	end

	--- Adds `amount` (default 1) to a plain event counter.
	--- @param name string Closed counter name, `family.counter`.
	--- @param amount number|nil Increment.
	function S.count(name, amount)
		_counters[name] = (_counters[name] or 0) + (amount or 1)
	end

	--- Returns the live figures of a phase, for tests and diagnostics.
	--- @param name string Phase name.
	--- @return table|nil figures { n, total_ms, max_ms }, nil when never recorded.
	function S.figures(name)
		local phase = _phases[name]
		if phase == nil then return nil end
		return { n = phase.n, total_ms = phase.total / NANOSECONDS_PER_MILLISECOND, max_ms = phase.max / NANOSECONDS_PER_MILLISECOND }
	end

	--- Returns a counter's value.
	--- @param name string Counter name.
	--- @return number
	function S.counter(name)
		return _counters[name] or 0
	end

	--- Names the long phases that ended at or after `since_ns`, longest first.
	--- Used by the slow-callback report to attribute a main-thread hold.
	--- @param since_ns number Timestamp from S.now() when the held callback began.
	--- @return string|nil list `name=12.3 ms, name=4.1 ms`, nil when none ran.
	function S.recent_since(since_ns)
		local found = {}
		for slot = 1, ATTRIBUTION_RING_SIZE do
			if _ring_name[slot] ~= nil and _ring_end[slot] >= since_ns then
				found[#found + 1] = { name = _ring_name[slot], dur = _ring_dur[slot] }
			end
		end
		if #found == 0 then return nil end
		table.sort(found, function(a, b) return a.dur > b.dur end)
		local parts = {}
		for index = 1, math.min(#found, MAX_ATTRIBUTED) do
			parts[index] = string.format("%s=%.1f ms", found[index].name, found[index].dur / NANOSECONDS_PER_MILLISECOND)
		end
		return table.concat(parts, ", ")
	end

	--- Clears every phase, counter and ring entry.
	function S.reset()
		_phases, _counters = {}, {}
		_ring_name, _ring_end, _ring_dur = {}, {}, {}
		_ring_head = 0
	end

	--- Emits one evidence line per family plus a memory line, then clears the
	--- counters. Text is formatted only when INFO is enabled.
	--- @param interval_sec number|nil Seconds the counters cover, shown in the line.
	--- @return integer lines Evidence lines emitted.
	function S.flush(interval_sec)
		local phases, counters = _phases, _counters
		S.reset()
		if not info_enabled() then return 0 end

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
					item.name:sub(#key + 2), item.phase.n, item.phase.total / item.phase.n / NANOSECONDS_PER_MILLISECOND,
					item.phase.max / NANOSECONDS_PER_MILLISECOND, item.phase.total / NANOSECONDS_PER_MILLISECOND)
			end
			for _, item in ipairs(entry.counters) do
				parts[#parts + 1] = string.format("#%s=%d", item.name:sub(#key + 2), item.value)
			end
			evidence("Phase summary [%s] over %d s: %s.", key,
				math.floor(interval_sec or M.DEFAULT_FLUSH_SECONDS), table.concat(parts, " | "))
			lines = lines + 1
		end
		evidence("Memory snapshot: lua=%d KB.", math.floor(collectgarbage("count")))
		return lines + 1
	end

	return S
end

return M
