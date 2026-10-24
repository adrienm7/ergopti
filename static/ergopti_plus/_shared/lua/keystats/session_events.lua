--- _shared/lua/keystats/session_events.lua

--- ==============================================================================
--- MODULE: Typing Session Events (Shared)
--- DESCRIPTION:
--- The rows of events_session: when a typing session starts and ends, and the
--- short idle spans inside it. This is the state machine macOS runs in
--- keystats/init.lua and watchers.lua and Windows in keystats_watchers.ahk,
--- kept free of any clock or timer so a driver ticks it and a test moves time
--- by hand. Linux is its first caller.
---
--- FEATURES & RATIONALE:
--- 1. A keystroke starts a session; any input (a key or the pointer) keeps it
---    alive and ends an idle span. Pointer activity alone starts nothing: the
---    session is a typing session.
--- 2. After timings [keystats] micro_idle_timeout_ms without input an idle span
---    starts; it ends at the next input, its duration counted from the moment
---    the span began. After session_timeout_ms the session ends instead, its
---    duration from its first to its last input.
--- 3. input() and tick() take `now_ms`, the caller's monotonic time. Every
---    function returns the events it produced, in order: { kind, duration_ms? }.
--- ==============================================================================

local M = {}

-- The kinds events_session's CHECK constraint accepts
M.SESSION_START = "session_start"
M.SESSION_END   = "session_end"
M.IDLE_START    = "idle_start"
M.IDLE_END      = "idle_end"




-- ===============================
-- ===============================
-- ======= 1/ Tracker ============
-- ===============================
-- ===============================

--- A fresh tracker.
--- @param opts table { micro_idle_ms, session_timeout_ms } from the shared timings.
--- @return table tracker { input(now_ms, is_keystroke), tick(now_ms), stop(now_ms) }
function M.new(opts)
	if type(opts) ~= "table" then error("session_events.new requires its timings", 2) end
	for _, key in ipairs({ "micro_idle_ms", "session_timeout_ms" }) do
		if type(opts[key]) ~= "number" or opts[key] <= 0 then
			error("session_events.new: " .. key .. " must be a positive number", 2)
		end
	end
	if opts.session_timeout_ms <= opts.micro_idle_ms then
		error("session_events.new: the session timeout must exceed the idle timeout", 2)
	end
	local micro_idle_ms, session_timeout_ms = opts.micro_idle_ms, opts.session_timeout_ms
	local tracker = {}
	local started_at, last_active, idle = nil, nil, false

	local function ended_session(events)
		events[#events + 1] = { kind = M.SESSION_END, duration_ms = math.max(0, last_active - started_at) }
		started_at, last_active, idle = nil, nil, false
		return events
	end

	--- Records one input.
	--- @param now_ms number
	--- @param is_keystroke boolean A key typed, as opposed to pointer activity.
	--- @return table events
	function tracker.input(now_ms, is_keystroke)
		assert(type(now_ms) == "number", "session_events input needs a time")
		local events = {}
		if started_at and now_ms - last_active > session_timeout_ms then ended_session(events) end
		if idle then
			events[#events + 1] = { kind = M.IDLE_END,
				duration_ms = math.max(0, now_ms - (last_active + micro_idle_ms)) }
			idle = false
		end
		if not started_at then
			if not is_keystroke then return events end
			started_at = now_ms
			events[#events + 1] = { kind = M.SESSION_START }
		end
		last_active = now_ms
		return events
	end

	--- Evaluates the silence since the last input.
	--- @param now_ms number
	--- @return table events
	function tracker.tick(now_ms)
		assert(type(now_ms) == "number", "session_events tick needs a time")
		local events = {}
		if not started_at then return events end
		local silent_ms = now_ms - last_active
		if silent_ms > session_timeout_ms then return ended_session(events) end
		if not idle and silent_ms > micro_idle_ms then
			idle = true
			events[#events + 1] = { kind = M.IDLE_START }
		end
		return events
	end

	--- Closes an open session, as at shutdown.
	--- @return table events
	function tracker.stop()
		if not started_at then return {} end
		return ended_session({})
	end

	return tracker
end

return M
