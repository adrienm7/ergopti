--- _shared/lua/tap_hold/copy_check.lua

--- ==============================================================================
--- MODULE: Copy Check (shared)
--- DESCRIPTION:
--- Proves that a copy keystroke sent by a tap-hold (Cmd+C on macOS, Ctrl+C on
--- Linux) reached the clipboard, retries it once when it did not, and reports a
--- copy that never landed so the driver can warn the user instead of leaving
--- them to paste the previous clipboard.
---
--- FEATURES & RATIONALE:
--- 1. The clipboard's change counter decides, never its content: copying the
---    same text again leaves the content unchanged but moves the counter
---    (NSPasteboard changeCount, GetClipboardSequenceNumber, the X11 selection
---    owner's timestamp). The baseline is read before the keystroke reaches the
---    application, so a copy that lands before the first check still counts.
--- 2. Non-blocking: every wait is a timer from the driver's `after` port; the
---    check never sleeps on the input thread.
--- 3. One check at a time: a new copy supersedes a pending one, whose retry
---    would otherwise send a second Cmd+C over the newer selection.
--- 4. Pure: the counter, the retry keystroke, the timer and the report are
---    ports, so the macOS and Linux tests drive it with a fake counter and a
---    fake clock. The Windows driver ports the same states in AHK
---    (platform/remap/constants.ahk, section 2.1).
--- ==============================================================================

local M = {}

-- How many times a copy is sent again when the clipboard did not move.
M.RETRIES = 1

M.COPIED = "copied"
M.COPIED_ON_RETRY = "copied_on_retry"
M.NOT_COPIED = "not_copied"
M.RETRY_REFUSED = "retry_refused"
M.COUNTER_UNREADABLE = "counter_unreadable"
M.TIMER_REFUSED = "timer_refused"
M.SUPERSEDED = "superseded"
M.CONTEXT_CHANGED = "context_changed"

-- The outcomes after which the user is told the copy did not happen.
local FAILURES = { [M.NOT_COPIED] = true, [M.RETRY_REFUSED] = true }

--- Whether an outcome means the clipboard never received the copy.
--- @param outcome string An outcome reported by a checker.
--- @return boolean failed
function M.is_failure(outcome)
	return FAILURES[outcome] == true
end

local Checker = {}
Checker.__index = Checker

--- Creates one checker.
--- @param ports table {
---   read_counter = function() -> number|nil, the clipboard change counter,
---   send_copy = function() -> boolean, sends the copy keystroke again,
---   after = function(delay_ms, callback) -> handle|nil, a one-shot timer,
---   cancel = function(handle)|nil, cancels a timer `after` returned,
---   report = function(outcome, detail), told once per check; detail is
---     { source, attempts, waited_ms },
---   verify_ms = number, how long each attempt waits before reading the counter,
--- }
--- @return table checker
function M.new(ports)
	assert(type(ports) == "table", "copy_check.new: ports must be a table")
	for _, name in ipairs({ "read_counter", "send_copy", "after", "report" }) do
		assert(type(ports[name]) == "function", "copy_check.new: port '" .. name .. "' must be a function")
	end
	assert(ports.cancel == nil or type(ports.cancel) == "function", "copy_check.new: cancel must be a function")
	local verify_ms = ports.verify_ms
	assert(type(verify_ms) == "number" and verify_ms > 0, "copy_check.new: verify_ms must be a positive number")
	return setmetatable({ ports = ports, verify_ms = verify_ms, pending = nil, generation = 0 }, Checker)
end

--- Reports one outcome and forgets the pending check.
--- @param pending table The check that ends.
--- @param outcome string Outcome name.
local function finish(self, pending, outcome)
	if self.pending ~= pending then return false end
	self.pending = nil
	self.ports.report(outcome, {
		source = pending.source,
		attempts = pending.attempts,
		waited_ms = pending.attempts * self.verify_ms,
	})
end

local check

--- Arms the timer of the pending check's current attempt.
--- @param pending table The pending check.
--- @return boolean armed
local function arm(self, pending)
	local generation = pending.generation
	local called, handle = pcall(self.ports.after, self.verify_ms, function() check(self, generation) end)
	if self.pending ~= pending or pending.generation ~= generation then
		if called and handle ~= nil and handle ~= false and self.ports.cancel then pcall(self.ports.cancel, handle) end
		return false
	end
	if not called or handle == nil or handle == false then
		finish(self, pending, M.TIMER_REFUSED)
		return false
	end
	pending.timer = handle
	return true
end

--- Reads the counter once an attempt has had its time.
--- @param generation number The check this timer belongs to.
check = function(self, generation)
	local pending = self.pending
	if pending == nil or pending.generation ~= generation then return end
	pending.timer = nil
	local called, counter = pcall(self.ports.read_counter)
	if self.pending ~= pending or pending.generation ~= generation then return end
	if not called or type(counter) ~= "number" then
		finish(self, pending, M.COUNTER_UNREADABLE)
		return
	end
	if counter ~= pending.baseline then
		finish(self, pending, pending.attempts > 1 and M.COPIED_ON_RETRY or M.COPIED)
		return
	end
	if pending.attempts > M.RETRIES then
		finish(self, pending, M.NOT_COPIED)
		return
	end
	if pending.retry_guard then
		local checked, current = pcall(pending.retry_guard)
		if self.pending ~= pending then return end
		if not checked or current ~= true then
			finish(self, pending, M.CONTEXT_CHANGED)
			return
		end
	end
	pending.attempts = pending.attempts + 1
	pending.baseline = counter
	local sent_ok, sent = pcall(self.ports.send_copy)
	if self.pending ~= pending or pending.generation ~= generation then return end
	if not sent_ok or sent ~= true then
		-- A retry its owner refused because the context changed meanwhile is not
		-- a copy failure: report it as such instead of warning the user.
		if pending.retry_guard then
			local checked, current = pcall(pending.retry_guard)
			if self.pending ~= pending or pending.generation ~= generation then return end
			if not checked or current ~= true then
				finish(self, pending, M.CONTEXT_CHANGED)
				return
			end
		end
		finish(self, pending, M.RETRY_REFUSED)
		return
	end
	arm(self, pending)
end

--- Starts checking one copy keystroke.
--- @param baseline number|nil The counter read before the keystroke reached the
---   application; nil when it could not be read.
--- @param source string What sent the copy, for the report.
--- @param retry_guard function|nil Must prove that retrying is still safe.
--- @return boolean started False when nothing can be checked.
function Checker:start(baseline, source, retry_guard)
	assert(retry_guard == nil or type(retry_guard) == "function", "copy_check.start: invalid retry guard")
	local generation = self.generation
	local previous = self.pending
	if previous ~= nil then
		self.pending = nil
		if previous.timer ~= nil and self.ports.cancel then pcall(self.ports.cancel, previous.timer) end
		self.ports.report(M.SUPERSEDED, {
			source = previous.source,
			attempts = previous.attempts,
			waited_ms = 0,
		})
	end
	if self.generation ~= generation then return false end
	self.generation = self.generation + 1
	local pending = { baseline = baseline, attempts = 1, source = tostring(source), generation = self.generation,
		retry_guard = retry_guard }
	if type(baseline) ~= "number" then
		self.ports.report(M.COUNTER_UNREADABLE, { source = pending.source, attempts = 1, waited_ms = 0 })
		return false
	end
	self.pending = pending
	return arm(self, pending)
end

--- Abandons the pending check without a report; used on stop and pause.
function Checker:stop()
	local pending = self.pending
	self.pending = nil
	self.generation = self.generation + 1
	if pending ~= nil and pending.timer ~= nil and self.ports.cancel then
		pcall(self.ports.cancel, pending.timer)
	end
end

--- Whether a check is waiting on its timer.
--- @return boolean
function Checker:is_pending()
	return self.pending ~= nil
end

--- Rounds a duration for a log line.
--- @param ms number|nil
--- @return string
local function ms_text(ms)
	if type(ms) ~= "number" then return "?" end
	return tostring(math.floor(ms + 0.5))
end

--- Builds the report port every driver uses: one log line per outcome and, for
--- a copy that never landed, the user's warning.
--- @param log function The central logger: log(level, fmt, ...), level one of
---   "debug", "info", "warn".
--- @param warn_user function Shows the localized notify.tap_hold.copy_failed.
--- @return function report
function M.reporter(log, warn_user)
	assert(type(log) == "function" and type(warn_user) == "function",
		"copy_check.reporter: log and warn_user must be functions")
	return function(outcome, detail)
		local source, waited = tostring(detail and detail.source), ms_text(detail and detail.waited_ms)
		if outcome == M.COPIED then
			log("debug", "Tap-hold copy from %s verified: the clipboard changed within %s ms.", source, waited)
		elseif outcome == M.COPIED_ON_RETRY then
			log("warn", "Tap-hold copy from %s reached the clipboard only when sent again (%s ms).", source, waited)
		elseif outcome == M.SUPERSEDED then
			log("debug", "Tap-hold copy check from %s superseded by a newer copy.", source)
		elseif outcome == M.CONTEXT_CHANGED then
			log("warn", "Tap-hold copy from %s could not be retried because its original context is no longer proven.", source)
		elseif M.is_failure(outcome) then
			log("warn", "Tap-hold copy from %s never reached the clipboard (%s after %s ms); the user is warned.",
				source, outcome, waited)
			warn_user()
		else
			log("warn", "Tap-hold copy from %s could not be checked (%s).", source, outcome)
		end
	end
end

return M
