--- _shared/lua/llm/request_plan/debounce.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Debounce and Rate Floor
--- DESCRIPTION:
--- The pure decision half of the prediction orchestration: when the automatic
--- trigger arms its timer, which delay it waits, whether a fired timer is still
--- the current one, and whether a request may go to its backend now or must wait
--- for the backend's minimum interval. The macOS and Linux prediction engines
--- own the native timers and the HTTP calls; they feed this plan the events and
--- the clock and carry out the decisions it returns.
---
--- FEATURES & RATIONALE:
--- 1. No IO and no clock: every method takes the time as an argument and returns
---    a list of decisions, so a transcript of events replays identically on any
---    driver (_shared/tests/corpus/llm/request_plan_debounce_vectors.json).
--- 2. One token per armed timer: a timer that fired after a newer arm or a cancel
---    answers `stale` and is dropped, so a superseded keystroke never sends.
--- 3. One behaviour for every driver, no per-driver option: "never" is a
---    negative debounce, an explicit request is never held by the floor, a word
---    end is instant in live mode too, and the last request time is one value.
---    A difference between drivers is a red vector, not a named option.
--- 4. The floor is a port: the plan asks `floor_ms()` (the user's
---    llm.trigger.min_request_interval_ms) and never reads the configuration
---    itself, so an invalid value fails where the setting lives.
---
--- The AutoHotkey twin (windows/modules/llm/prediction_keystats.ahk and
--- prediction_exec.ahk) replays the same vectors when its side is ported.
--- ==============================================================================

local M = {}





-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- The debounce that turns the automatic trigger off ("never"). It is the value
-- the configuration file stores (llm.trigger.debounce_ms) and every driver's
-- menu offers; any negative number given to the plan means the same.
M.NEVER_MS = -1

-- The causes an input event may carry.
M.CAUSES = {
	typing = true,
	explicit_trigger = true,
	expiry = true,
	override = true,
}

-- The log label (the `why` of every arm decision), shared so both drivers log the same words.
M.REASON = {
	inactivity = "Inactivity",
	word_end = "Word-end",
	live = "Live",
	explicit_trigger = "Explicit-trigger",
	expiry = "Hotstring-expiry",
	live_expiry = "Live hotstring-expiry",
	override = "Override",
}




-- =================================
-- =================================
-- ======= 2/ Construction =========
-- =================================
-- =================================

--- Raises when a value is not a non-negative finite number.
--- @param value any Candidate.
--- @param name string Its name for the message.
local function require_delay(value, name)
	if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
		error(name .. " must be a non-negative finite number", 3)
	end
end

--- Creates a plan.
--- @param floor_ms function The floor port: returns the user's minimum interval
---   between two automatic requests, in milliseconds, read at every dispatch.
--- @return table plan
function M.new(floor_ms)
	if type(floor_ms) ~= "function" then error("the request plan needs a floor_ms function", 2) end
	local plan = {
		_settings = {
			floor_ms = floor_ms,
			-- The configured debounce, the AI switch and the live mode are runtime
			-- settings, changed by M.configure; they start off.
			debounce_ms = nil,
			instant_on_word_end = false,
			enabled = false,
			live_debounce_ms = nil,
		},
		_pending = nil,
		_next_token = 1,
		_last_sent_ms = nil,
	}
	return setmetatable(plan, { __index = M })
end




-- =================================
-- =================================
-- ======= 3/ Settings =============
-- =================================
-- =================================

--- Applies runtime settings; a key left out keeps its value.
--- @param settings table { enabled, debounce_ms, instant_on_word_end, live_debounce_ms }.
---   live_debounce_ms = false turns live mode off.
function M:configure(settings)
	local own = self._settings
	if type(settings) ~= "table" then error("configure needs a settings table", 2) end
	if settings.enabled ~= nil then
		if type(settings.enabled) ~= "boolean" then error("enabled must be a boolean", 2) end
		own.enabled = settings.enabled
	end
	if settings.debounce_ms ~= nil then
		local value = settings.debounce_ms
		if type(value) ~= "number" or value ~= value then error("debounce_ms must be a number", 2) end
		-- A negative debounce is "never" (M.NEVER_MS); anything else is a delay.
		if value >= 0 then require_delay(value, "the debounce") end
		own.debounce_ms = value
	end
	if settings.instant_on_word_end ~= nil then
		if type(settings.instant_on_word_end) ~= "boolean" then error("instant_on_word_end must be a boolean", 2) end
		own.instant_on_word_end = settings.instant_on_word_end
	end
	if settings.live_debounce_ms ~= nil then
		if settings.live_debounce_ms == false then
			own.live_debounce_ms = nil
		else
			require_delay(settings.live_debounce_ms, "the live debounce")
			own.live_debounce_ms = settings.live_debounce_ms
		end
	end
end




-- =================================
-- =================================
-- ======= 4/ The Timer ============
-- =================================
-- =================================

--- Arms a fresh token for a delay, superseding the pending one.
--- @param self table The plan.
--- @param decisions table Decision list being built.
--- @param delay_ms number Delay to wait.
--- @param why string Log label.
--- @return table decisions The list, with the `cancel` and the `arm` appended.
local function arm(self, decisions, delay_ms, why)
	if self._pending then
		decisions[#decisions + 1] = { action = "cancel", token = self._pending.token }
	end
	local token = self._next_token
	self._next_token = token + 1
	self._pending = { token = token, why = why }
	decisions[#decisions + 1] = { action = "arm", token = token, delay_ms = delay_ms, why = why }
	return decisions
end

--- Decides what one input event does to the debounce timer.
--- @param event table { cause = "typing"|"explicit_trigger"|"expiry"|"override",
---   ends_word = boolean|nil (typing), delay_ms = number|nil (override) }.
--- @return table decisions An `arm` (after a `cancel` of the pending one) or a `skip`.
function M:on_input(event)
	local own = self._settings
	if type(event) ~= "table" or not M.CAUSES[event.cause] then
		error("input event needs a known cause", 2)
	end
	local live = own.live_debounce_ms ~= nil
	if not own.enabled then return { { action = "skip", why = "disabled" } } end
	if event.cause == "expiry" then
		return arm(self, {}, 0, live and M.REASON.live_expiry or M.REASON.expiry)
	end
	if own.debounce_ms == nil then error("debounce_ms was never configured", 2) end
	if event.cause == "explicit_trigger" then
		return arm(self, {}, math.max(0, own.debounce_ms), M.REASON.explicit_trigger)
	end
	-- "Never" turns the automatic trigger off; live mode is an explicit request for it.
	if own.debounce_ms < 0 and not live then return { { action = "skip", why = "automatic trigger off" } } end
	if event.cause == "override" then
		require_delay(event.delay_ms, "the override delay")
		return arm(self, {}, event.delay_ms, M.REASON.override)
	end
	if live and not (event.ends_word == true and own.instant_on_word_end) then
		return arm(self, {}, own.live_debounce_ms, M.REASON.live)
	end
	if event.ends_word == true and own.instant_on_word_end then
		return arm(self, {}, 0, M.REASON.word_end)
	end
	return arm(self, {}, own.debounce_ms, M.REASON.inactivity)
end

--- Cancels the pending timer, if any.
--- @return table decisions One `cancel`, or none.
function M:on_cancel()
	local pending = self._pending
	if not pending then return {} end
	self._pending = nil
	return { { action = "cancel", token = pending.token } }
end

--- Answers a native timer that fired.
--- @param token number The token its `arm` decision carried.
--- @return table decisions One `fire` when it is the pending timer, else one `stale`.
function M:on_timer(token)
	local pending = self._pending
	if pending and pending.token == token then
		self._pending = nil
		return { { action = "fire", token = token, why = pending.why } }
	end
	return { { action = "stale", token = token } }
end





-- =================================
-- =================================
-- ======= 5/ The Rate Floor =======
-- =================================
-- =================================

--- Decides whether a request may go to its backend now. The last request time is
--- one value for every backend and every kind of request, and the interval is the
--- one the user sets (llm.trigger.min_request_interval_ms).
--- @param request table { explicit = boolean|nil, variant = integer|nil (1-based) }. The floor
---   applies between distinct requests only: an explicit request (shortcut, typed trigger,
---   prompt action) is never held, and the variants of one request (the later calls of a
---   "predict n" run, automatic or explicit) are part of it, so from the second on they are
---   never held either. Only the first call of an automatic request waits.
--- @param now_ms number The caller's monotonic clock in milliseconds.
--- @return table decisions One `send`, or one `defer` with the milliseconds to wait.
function M:on_dispatch(request, now_ms)
	if type(request) ~= "table" then error("a dispatch needs a request table", 2) end
	if type(now_ms) ~= "number" then error("a dispatch needs the clock", 2) end
	if request.explicit == true or (request.variant or 1) > 1 then return { { action = "send" } } end
	local last = self._last_sent_ms
	if last == nil then return { { action = "send" } } end
	local interval = self._settings.floor_ms()
	require_delay(interval, "the request floor")
	local wait = last + interval - now_ms
	if wait > 0 then return { { action = "defer", delay_ms = wait, why = "rate floor" } } end
	return { { action = "send" } }
end

--- Decides what pressing an explicit shortcut does while the request its previous
--- press started may still be in flight (a mashed shortcut). The new request is
--- never delayed; the one in flight under the same shortcut is superseded, so
--- two requests of one shortcut are never concurrent. The engine owns the
--- request and tells whether it is in flight; this only decides.
--- @param request table { key = string (the shortcut's identity), in_flight = boolean }.
--- @return table decisions A `supersede` of the key when in flight, then one `send`.
function M:on_explicit(request)
	if type(request) ~= "table" or type(request.key) ~= "string" or request.key == "" then
		error("an explicit request needs a shortcut key", 2)
	end
	if type(request.in_flight) ~= "boolean" then error("an explicit request needs in_flight", 2) end
	if request.in_flight then
		return { { action = "supersede", key = request.key }, { action = "send" } }
	end
	return { { action = "send" } }
end

--- Records that a request went to its backend.
--- @param now_ms number The caller's monotonic clock in milliseconds.
function M:on_sent(now_ms)
	if type(now_ms) ~= "number" then error("a sent request needs the clock", 2) end
	self._last_sent_ms = now_ms
end

--- Forgets every request time and the pending timer (engine re-initialisation).
function M:reset()
	self._pending = nil
	self._last_sent_ms = nil
end

return M
