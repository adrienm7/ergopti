--- modules/keystats/ingest_trace.lua

--- Names the phase of a slow keystats ingest tick. Issue #101 showed the ingest
--- timer callback holding the main thread for 1.0 to 1.4 s, which delays event
--- taps and the Karabiner lease heartbeat; the generic slow-callback report
--- names the callback but not whether the foreign data.sql rebuild, the SQLite
--- commit or the ledger append dominated. One compact line carries the answer.
local M = {}

--- A tick shorter than this is not worth a line; it matches the generic
--- slow-callback threshold so both reports describe the same hold.
M.REPORT_THRESHOLD_MS = 500
--- One report per minute: a persistently slow tick would otherwise log every
--- ingest interval.
M.REPORT_REPEAT_MS = 60000

local NANOSECONDS_PER_MILLISECOND = 1000000
local PHASE_ORDER = { "drain", "foreign", "outbox", "read", "build", "apply", "commit", "append", "notify" }

local _last_report_ms = nil

--- Starts one trace.
--- @param clock function Returns monotonic nanoseconds.
--- @param emit function Receives the finished line.
--- @return table trace With mark(phase), count(name, value) and finish().
function M.begin(clock, emit)
	assert(type(clock) == "function" and type(emit) == "function",
		"IngestTrace.begin: clock and emit functions are required")
	local started = clock()
	local last = started
	local phases, counts = {}, {}
	local trace = {}

	--- Charges the time since the previous mark to one phase.
	function trace.mark(phase)
		local now = clock()
		phases[phase] = (phases[phase] or 0) + (now - last) / NANOSECONDS_PER_MILLISECOND
		last = now
	end

	--- Records an integer size shown beside the timings (never content).
	function trace.count(name, value)
		counts[name] = value
	end

	--- Closes the trace and emits one line when the tick was slow.
	--- @return boolean reported True when a line was emitted.
	function trace.finish()
		trace.mark("notify")
		local now = clock()
		local total_ms = (now - started) / NANOSECONDS_PER_MILLISECOND
		if total_ms < M.REPORT_THRESHOLD_MS then return false end
		local now_ms = now / NANOSECONDS_PER_MILLISECOND
		if _last_report_ms and now_ms - _last_report_ms < M.REPORT_REPEAT_MS then return false end
		_last_report_ms = now_ms
		local parts = {}
		for _, phase in ipairs(PHASE_ORDER) do
			parts[#parts + 1] = string.format("%s=%d", phase, math.floor(phases[phase] or 0))
		end
		emit(string.format("Slow ingest tick %d ms (%s ms; entries=%d statements=%d).",
			math.floor(total_ms), table.concat(parts, " "),
			counts.entries or 0, counts.statements or 0))
		return true
	end

	return trace
end

--- Forgets the report rate limit (tests only).
function M.reset_for_tests()
	_last_report_ms = nil
end

return M
