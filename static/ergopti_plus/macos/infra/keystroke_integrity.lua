--- infra/keystroke_integrity.lua

--- ==============================================================================
--- MODULE: Keystroke Integrity Ring
--- DESCRIPTION:
--- Keeps, for the last physical key-downs the driver decided, only the decision
--- and its time in a fixed ring: never the key, its code or its text, so the
--- ring holds less than the keystats ledger already may. A typed key that the
--- driver consumed and then never delivered is reported with one WARNING that
--- carries the ring's recent decisions.
---
--- FEATURES & RATIONALE:
--- 1. A dropped letter has two possible owners: this driver (a consumed press
---    whose replay never posted, a stale one-shot claim) or something upstream
---    of every event tap (a Karabiner configuration reload, a tap outage). Only
---    the first can be seen from here, so its absence next to a reported drop
---    points at the second.
--- 2. Recording is one table write per key-down; logging is deferred off the
---    event tap and coalesced into one line per run-loop turn.
--- 3. Exposure: a lease fence or a tap outage reports how many key-downs of the
---    preceding seconds crossed it, the upstream losses point 1 cannot see.
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local DeferredWork = require("infra.deferred_work")
local Timer        = require("adapters.timer_scheduler")

local LOG = "keystroke_integrity"

-- 64 decisions span several seconds of fast typing, enough to see what the
-- driver did just before a drop, and stay small enough for a diagnostic line.
M.RING_SIZE = 64

-- Only the decisions shown in a report summary over this window are counted.
M.SUMMARY_WINDOW_MS = 10000

-- A key typed this close to a rule switch or a tap outage may have been held
-- across it: Karabiner drops a manipulation whose rules changed, and a disabled
-- tap misses the press it should have decided.
M.EXPOSURE_WINDOW_MS = 2000

M.DECISIONS = {
	passed        = true, -- the key reached the application unchanged or modified
	consumed      = true, -- the driver typed something in its place
	replay_queued = true, -- consumed behind older synthetic output, to be replayed
	replay_posted = true, -- that delayed replay reached Quartz
	stale_claim   = true, -- a fresh press found a claim whose release was missed
	error         = true, -- the keyboard callback raised
}

local NS_PER_MS = 1e6

local _times     = {}
local _decisions = {}
local _head      = 0
local _filled    = 0
local _drops     = 0
local _pending   = {}
local _pending_scheduled = false
-- Declared before M.reset, which clears them.
local _exposures = {}
local _exposures_scheduled = false

--- Clears the ring and every counter; tests and a full driver stop use it.
function M.reset()
	_times, _decisions = {}, {}
	_head, _filled, _drops = 0, 0, 0
	_pending = {}
	_pending_scheduled = false
	_exposures = {}
	_exposures_scheduled = false
end

--- Records one decision about a physical key-down.
--- @param decision string One of M.DECISIONS.
function M.record(decision)
	assert(M.DECISIONS[decision] == true,
		"infra.keystroke_integrity.record: unknown decision " .. tostring(decision))
	_head = _head % M.RING_SIZE + 1
	_times[_head] = Timer.now_ns() / NS_PER_MS
	_decisions[_head] = decision
	if _filled < M.RING_SIZE then _filled = _filled + 1 end
end

--- Records a decision from an input path, where a diagnostic failure must
--- never change what the key does: a raise there would skip the fence or the
--- settlement the decision describes.
--- @param decision string One of M.DECISIONS.
--- @return boolean recorded
function M.note(decision)
	return (pcall(M.record, decision))
end

--- Summarizes the ring's decisions of the last SUMMARY_WINDOW_MS.
--- @return string summary "decision=count, …" in a stable order, or "none".
function M.summary()
	local now_ms = Timer.now_ns() / NS_PER_MS
	local counts = {}
	for index = 1, _filled do
		if now_ms - _times[index] <= M.SUMMARY_WINDOW_MS then
			local decision = _decisions[index]
			counts[decision] = (counts[decision] or 0) + 1
		end
	end
	local names = {}
	for name in pairs(counts) do names[#names + 1] = name end
	if #names == 0 then return "none" end
	table.sort(names)
	local parts = {}
	for _, name in ipairs(names) do
		parts[#parts + 1] = string.format("%s=%d", name, counts[name])
	end
	return table.concat(parts, ", ")
end

--- Returns how many swallowed keys were reported since the last reset.
--- @return integer drops
function M.drop_count()
	return _drops
end

local function flush_pending()
	_pending_scheduled = false
	local pending = _pending
	_pending = {}
	local summary = M.summary()
	for cause, count in pairs(pending) do
		Logger.warn(LOG, "%d typed key(s) swallowed: Ergopti consumed them and %s"
			.. " (key decisions of the last %d s: %s).",
			count, cause, M.SUMMARY_WINDOW_MS // 1000, summary)
	end
end

--- Counts the key-downs the ring holds from the last `window_ms`.
--- @param window_ms number Window length in milliseconds.
--- @return integer count
function M.recent_count(window_ms)
	local now_ms = Timer.now_ns() / NS_PER_MS
	local count = 0
	for index = 1, _filled do
		if now_ms - _times[index] <= window_ms then count = count + 1 end
	end
	return count
end

local function flush_exposures()
	_exposures_scheduled = false
	local exposures = _exposures
	_exposures = {}
	for cause, count in pairs(exposures) do
		Logger.warn(LOG, "%d key-down(s) of the last %d ms were typed across %s: a key held or"
			.. " in flight then can be lost upstream of every Ergopti event tap.",
			count, M.EXPOSURE_WINDOW_MS, cause)
	end
end

--- Reports, when the user was typing, that keys crossed an input transition the
--- ring cannot see past (issue #99 reported swallowed keys and logged no drop:
--- every one of them happened upstream). Silent without recent key-downs, and
--- safe anywhere: the WARNING is written on a later run-loop turn.
--- @param cause string Lower-case noun phrase completing "typed across …".
--- @return boolean reported Whether recent key-downs made it worth a line.
function M.report_exposure(cause)
	assert(type(cause) == "string" and cause ~= "",
		"infra.keystroke_integrity.report_exposure: cause must be non-empty")
	local count = M.recent_count(M.EXPOSURE_WINDOW_MS)
	if count == 0 then return false end
	_exposures[cause] = math.max(_exposures[cause] or 0, count)
	if not _exposures_scheduled then
		_exposures_scheduled = DeferredWork.after(0, flush_exposures, "keystroke exposure report")
	end
	return true
end

--- Reports an exposure from a path whose own outcome a diagnostic failure must
--- never change.
--- @param cause string See report_exposure.
--- @return boolean reported
function M.note_exposure(cause)
	local ok, reported = pcall(M.report_exposure, cause)
	return ok and reported == true
end

--- Reports one typed key the driver consumed and never delivered. Safe inside
--- an event-tap callback: the WARNING is written on a later run-loop turn.
--- @param cause string Lower-case clause completing "Ergopti consumed them and …".
function M.report_drop(cause)
	assert(type(cause) == "string" and cause ~= "",
		"infra.keystroke_integrity.report_drop: cause must be non-empty")
	_drops = _drops + 1
	_pending[cause] = (_pending[cause] or 0) + 1
	if _pending_scheduled then return end
	_pending_scheduled = DeferredWork.after(0, flush_pending, "keystroke integrity report")
end

return M
