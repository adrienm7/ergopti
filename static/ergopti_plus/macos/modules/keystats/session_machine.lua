--- modules/keystats/session_machine.lua

--- ==============================================================================
--- MODULE: Keystats Typing Session Machine
--- DESCRIPTION:
--- The events_session rows of macOS: when a typing session starts and ends and
--- the idle spans inside it. The event tap (init.lua), the idle timer
--- (watchers.lua), the session reset and the engine stop all move the session
--- through these functions, so the rules live in one place on this driver.
---
--- FEATURES & RATIONALE:
--- 1. The rules are those of _shared/tests/corpus/keystats/session_events_vectors.json,
---    which this driver replays through its real event tap, idle timer and stop
---    (tests/unit/modules/keystats/core/test_corpus_keystats_session_events.lua).
---    Linux runs the closure-owned _shared/metrics/engine/system/session_events.lua;
---    macOS keeps its state in CoreState because the live WPM readout and the
---    deferred synthetic snapshot read and extend the same session fields.
--- 2. Any input, a key or the pointer, ends an idle span and keeps an open
---    session alive; only a keystroke opens one. An input that arrives after a
---    missed timeout (no idle tick ran, as across a sleep) ends the old session
---    first, so the silence is never counted as typing time.
--- 3. Each caller passes the limits it read from the timing registry
---    ([keystats] micro_idle_timeout_ms and session_timeout_ms) when it loaded,
---    so this module holds no copy a test stub could leave stale.
--- 4. close() is the single way to end a session: it writes session_end with the
---    time from the first to the last input and starts a new session generation
---    so a queued synthetic snapshot cannot reopen it.
--- ==============================================================================

local M = {}





-- ==============================
-- ==============================
-- ======= 1/ Transitions =======
-- ==============================
-- ==============================

--- Ends the open session, if any, and clears the session fields.
--- @param state table Keystats CoreState.
--- @param append_log function Accepts one log entry.
function M.close(state, append_log)
	if state.session_start_time > 0 then
		append_log({
			type        = "session_end",
			duration_ms = math.max(0, state.session_last_active - state.session_start_time),
		})
	end
	state.session_generation  = (state.session_generation or 0) + 1
	state.session_start_time  = 0
	state.session_last_active = 0
	state.is_micro_idle       = false
end

--- Records one input against the session.
--- @param state table Keystats CoreState.
--- @param append_log function Accepts one log entry.
--- @param limits table { micro_idle_ms, session_timeout_ms } from the timing registry.
--- @param now number Monotonic milliseconds.
--- @param is_keystroke boolean A typed key, as opposed to the pointer or a modifier.
function M.input(state, append_log, limits, now, is_keystroke)
	if state.session_start_time > 0 and now - state.session_last_active > limits.session_timeout_ms then
		M.close(state, append_log)
	end
	if state.is_micro_idle then
		state.is_micro_idle = false
		append_log({
			type        = "idle_end",
			duration_ms = math.max(0, now - (state.session_last_active + limits.micro_idle_ms)),
		})
	end
	if state.session_start_time == 0 then
		if not is_keystroke then return end
		state.session_start_time = now
		append_log({ type = "session_start" })
	end
	state.session_last_active = now
end

--- Evaluates the silence since the last input, as the idle timer does.
--- @param state table Keystats CoreState.
--- @param append_log function Accepts one log entry.
--- @param limits table { micro_idle_ms, session_timeout_ms } from the timing registry.
--- @param now number Monotonic milliseconds.
--- @return string|nil transition "idle_start" or "session_end" when one was written.
function M.tick(state, append_log, limits, now)
	if state.session_start_time == 0 then return nil end
	local silent_ms = now - state.session_last_active
	if silent_ms > limits.session_timeout_ms then
		M.close(state, append_log)
		return "session_end"
	end
	if not state.is_micro_idle and silent_ms > limits.micro_idle_ms then
		state.is_micro_idle = true
		append_log({ type = "idle_start" })
		return "idle_start"
	end
	return nil
end

return M
