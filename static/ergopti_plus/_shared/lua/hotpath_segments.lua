--- _shared/lua/hotpath_segments.lua

--- ==============================================================================
--- MODULE: Hot-path Segment Inventory (Lua drivers)
--- DESCRIPTION:
--- The one declaration of which latency segments the macOS and Linux drivers
--- measure, which of them each driver emits, and from what duration a segment is
--- reported as slow. The Windows driver keeps the equivalent list in
--- tools/test/test-hotpath-segments-declared.cjs (AutoHotkey source cannot load
--- Lua); this file is the Lua counterpart, so "what is measured" has exactly one
--- answer per driver.
---
--- FEATURES & RATIONALE:
--- 1. Instrumentation is the one kind of code whose absence is invisible: a
---    deleted segment leaves a profile that looks clean. Each entry therefore
---    says why it exists, and tests/unit/.../test_hotpath_segments_declared.lua
---    (shared contract test/hotpath_segments_contract.lua) fails when the
---    driver emits a segment that is not listed or no longer emits one that is.
--- 2. One threshold policy. The registry value [logger] hotpath_slow_ms (5 ms,
---    the same on the three drivers) applies to every segment; the caller reads
---    it and passes it in, so this module holds no copy of the number. An entry
---    may carry slow_ms only together with the measurement that justifies it, as
---    on Windows, because an override without evidence hides a regression.
--- 3. Names and numbers only. A segment name is a source constant; typed text,
---    paths and window titles never enter a segment, a threshold or a log line.
--- 4. Nesting attribution (new_nesting). A segment's slowness is judged on its
---    own time: the wall clock minus the segments that opened and closed inside
---    it. A slow segment is reported with its nearest enclosing declared
---    segment, so a 12 ms expansion inside a keystroke reads as the expansion's
---    cost, not as two slow lines that bill the same 12 ms twice. Vectors:
---    _shared/tests/corpus/diagnostics/hotpath_nesting_vectors.json. The Windows
---    profiler (infra/hotpath_profiler.ahk, _HotPathNestedMs) prints the
---    exclusive time but still judges and reports on the wall clock.
--- ==============================================================================

local M = {}

-- A segment that stays slow (a stalled disk, a busy compositor) is slow on every
-- keystroke; one WARNING per segment per window keeps the first occurrence and
-- the log readable. The counters keep counting every occurrence.
M.LOG_WINDOW_MS = 10000

local MACOS, LINUX = "macos", "linux"

-- Order: the keystroke path first, then output, then render, because that is the
-- order a latency investigation walks them in.
M.SEGMENTS = {
	{ name = "keydown", drivers = { MACOS },
		why = "the whole event-tap callback of one physical key press: provenance, trigger matching, preview, synthetic output" },
	{ name = "hotstring.match", drivers = { MACOS, LINUX },
		why = "the hotstring engine consuming one character: trigger matching, before any output" },
	{ name = "preview.rebuild", drivers = { MACOS },
		why = "refreshing the expansion and prediction preview after a key that fired nothing" },
	{ name = "hotstring.expand", drivers = { MACOS, LINUX },
		why = "building one expansion's output (erase + replacement) as a single transaction" },
	{ name = "tooltip.show_predictions", drivers = { MACOS },
		why = "rendering the streamed LLM prediction tooltip, re-fired per token" },
	{ name = "input.dispatch", drivers = { LINUX },
		why = "one keyboard event end to end: tap-hold, character callback, hotstring match, output" },
	{ name = "taphold.process", drivers = { LINUX },
		why = "the tap-hold engine deciding one physical event, ahead of every other consumer" },
	{ name = "input.char", drivers = { LINUX },
		why = "the character callback: keystats, hotstring engine, prediction and dynamic hotstrings" },
	{ name = "output.uinput_write", drivers = { LINUX },
		why = "one event written to the virtual keyboard, the only blocking write of the injection path" },
	{ name = "keystats.ingest", drivers = { LINUX },
		why = "recording one keystroke, which closes the per-keystroke budget" },
}

local _by_name = {}
for _, segment in ipairs(M.SEGMENTS) do
	assert(_by_name[segment.name] == nil, "duplicate hot-path segment " .. segment.name)
	assert(type(segment.why) == "string" and segment.why ~= "", "segment without a reason: " .. segment.name)
	assert(segment.slow_ms == nil or (type(segment.measured) == "string" and segment.measured ~= ""),
		"slow_ms override without its measurement: " .. segment.name)
	_by_name[segment.name] = segment
end

--- Returns the segments one driver emits, by name.
--- @param driver string "macos" or "linux".
--- @return table segments name -> entry.
function M.for_driver(driver)
	local found = {}
	for _, segment in ipairs(M.SEGMENTS) do
		for _, owner in ipairs(segment.drivers) do
			if owner == driver then found[segment.name] = segment end
		end
	end
	return found
end

--- Returns the slow threshold of a segment in milliseconds.
--- @param name string Segment name.
--- @param default_ms number The registry's [logger] hotpath_slow_ms.
--- @return number threshold_ms The segment's own override, else default_ms.
function M.threshold_ms(name, default_ms)
	assert(type(default_ms) == "number" and default_ms > 0, "threshold_ms needs the registry default in milliseconds")
	local segment = _by_name[name]
	return segment and segment.slow_ms or default_ms
end

--- Creates the per-segment rate limiter of the slow-segment WARNING. Only the
--- log line is limited: callers keep counting every slow occurrence themselves.
--- The first slow occurrence of a segment is always admitted.
--- @return function admit(name, now_ms) -> boolean admitted, number suppressed
---   `suppressed` counts the occurrences withheld since the previous line of
---   that segment (0 when not admitted).
function M.new_slow_gate()
	local last_logged, withheld = {}, {}
	return function(name, now_ms)
		local previous = last_logged[name]
		if previous ~= nil and now_ms - previous < M.LOG_WINDOW_MS then
			withheld[name] = (withheld[name] or 0) + 1
			return false, 0
		end
		local skipped = withheld[name] or 0
		last_logged[name], withheld[name] = now_ms, 0
		return true, skipped
	end
end

-- Deepest nesting a tracker follows. Segments nest a few levels deep (loop tick,
-- dispatch, character, match); a deeper stack is a clock read never closed.
M.MAX_NESTING_DEPTH = 32

-- Parent token of a slow segment that no declared segment encloses.
M.NO_PARENT = "none"

--- Creates a nesting tracker for one driver.
---
--- Every measured span opens a frame with open() and closes it with close().
--- Spans that are not declared segments (an idle wait, a tray build) are
--- transparent: their time counts as their enclosing segment's own time and
--- the slow segments inside them are reported with that enclosing segment.
--- A frame left open by a raise is closed with its enclosing frame: everything
--- opened after a closing span's start ended before it, in a single thread.
--- Reports are delivered once the parent is known, at the latest when the
--- outermost frame closes, children before their parent.
--- @param threshold_of function(name) -> number|nil Slow threshold in ms, nil for a span that is not a declared segment.
--- @param emit function(report, now_ms) Receives { segment, parent, total_ms, own_ms } of each slow segment.
--- @return table tracker { open(now_ms) -> now_ms, close(name, started_ms, now_ms) -> total_ms, own_ms, slow }
function M.new_nesting(threshold_of, emit)
	assert(type(threshold_of) == "function" and type(emit) == "function",
		"new_nesting needs a threshold reader and a report sink")
	local starts, nested, pending = {}, {}, {}
	local depth = 0

	-- Hands the waiting reports of a frame to the frame below, or emits them
	-- without a parent when no frame is left.
	local function hand_down(reports, parent, now_ms)
		if reports == nil then return end
		if parent ~= nil then
			for _, report in ipairs(reports) do
				report.parent = parent
				emit(report, now_ms)
			end
		elseif depth == 0 then
			for _, report in ipairs(reports) do
				report.parent = M.NO_PARENT
				emit(report, now_ms)
			end
		else
			local below = pending[depth]
			if below == nil then pending[depth] = reports
			else for _, report in ipairs(reports) do below[#below + 1] = report end end
		end
	end

	-- Pops the top frame; its measured children count against the frame below.
	local function pop()
		local child_ms, reports = nested[depth], pending[depth]
		pending[depth] = nil
		depth = depth - 1
		return child_ms, reports
	end

	local tracker = {}

	--- Opens a frame.
	--- @param now_ms number Monotonic milliseconds.
	--- @return number now_ms The stamp to pass to close().
	function tracker.open(now_ms)
		if depth >= M.MAX_NESTING_DEPTH then
			error("hot-path nesting deeper than " .. M.MAX_NESTING_DEPTH .. ": a span was opened and never closed", 2)
		end
		depth = depth + 1
		starts[depth], nested[depth], pending[depth] = now_ms, 0, nil
		return now_ms
	end

	--- Closes the frame opened at started_ms.
	--- @param name string Span name.
	--- @param started_ms number The stamp open() returned.
	--- @param now_ms number Monotonic milliseconds.
	--- @return number total_ms, number own_ms, boolean slow
	function tracker.close(name, started_ms, now_ms)
		-- Frames opened after this span started and still open were abandoned.
		while depth > 0 and starts[depth] > started_ms do
			local child_ms, reports = pop()
			if depth > 0 then nested[depth] = nested[depth] + child_ms end
			hand_down(reports, nil, now_ms)
		end
		local child_ms, reports = 0, nil
		if depth > 0 and starts[depth] == started_ms then child_ms, reports = pop() end
		local total_ms = now_ms - started_ms
		local own_ms = total_ms - child_ms
		local limit = threshold_of(name)
		if limit == nil then
			if depth > 0 then nested[depth] = nested[depth] + child_ms end
			hand_down(reports, nil, now_ms)
			return total_ms, own_ms, false
		end
		if depth > 0 then nested[depth] = nested[depth] + total_ms end
		hand_down(reports, name, now_ms)
		local slow = own_ms > limit
		if slow then hand_down({ { segment = name, total_ms = total_ms, own_ms = own_ms } }, nil, now_ms) end
		return total_ms, own_ms, slow
	end

	--- Current number of open frames, for tests.
	--- @return integer
	function tracker.depth() return depth end

	return tracker
end

--- The phase name a segment's timings are recorded under (PhaseStats and the
--- closed phase enum of the log vocabulary list `hotpath.<segment>` for each
--- declared segment). An undeclared name raises: a measurement under an unlisted
--- phase would escape the vocabulary gate.
--- @param name string Declared segment name.
--- @return string phase
function M.phase(name)
	if _by_name[name] == nil then error("undeclared hot-path segment: " .. tostring(name), 2) end
	return "hotpath." .. name
end

--- Returns whether a name is a declared segment of any driver.
--- @param name string
--- @return boolean
function M.is_declared(name)
	return _by_name[name] ~= nil
end

return M
