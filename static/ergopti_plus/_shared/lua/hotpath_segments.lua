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

--- Returns whether a name is a declared segment of any driver.
--- @param name string
--- @return boolean
function M.is_declared(name)
	return _by_name[name] ~= nil
end

return M
