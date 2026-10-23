--- adapters/event_clock.lua

--- ==============================================================================
--- MODULE: Quartz Event Clock Adapter (Hammerspoon)
--- DESCRIPTION:
--- Reads how late a keyboard event reaches an event tap, and how far apart two
--- events were stamped by the window server, in milliseconds.
---
--- FEATURES & RATIONALE:
--- 1. One clock domain: CGEventGetTimestamp and hs.timer.absoluteTime() both
---    derive from mach_absolute_time. Hammerspoon 1.1.1 converts the second to
---    nanoseconds and hands the first over raw, documented as nanoseconds but
---    possibly raw ticks (125/3 ns on Apple silicon); both readings are tried.
--- 2. No guessed architecture: the event stamp is read under each candidate
---    scale and the smallest plausible age is used. The wrong scale reads an
---    Apple silicon stamp as almost the whole uptime and an Intel stamp as a
---    negative age, so it can never win; a synthesized event (stamp 0) has no
---    plausible age and callers keep their ordinary behaviour.
--- 3. Lateness, not age: a callback is late by its age minus the smallest age of
---    the last FLOOR_WINDOW events. Any constant offset between the two clocks
---    (a stamp domain that also counts sleep, say) cancels out instead of making
---    every event look late, and a fresh event is never late.
--- 4. Bounded hot path: two field reads, two multiplications and a 32-slot scan
---    per event; it runs inside event-tap callbacks.
--- ==============================================================================

local M = {}

-- Nanoseconds per raw event stamp unit: 1 on Intel, 125/3 on Apple silicon.
M.SCALES = { 1, 125 / 3 }

-- Longer than any main-thread freeze a report has shown (13.4 s, issue #99): a
-- stamp older than this is a wrong scale or a stale clock, not a late event.
M.MAX_PLAUSIBLE_AGE_MS = 60000

-- Stamps and the host clock come from different reads; allow this much skew.
M.MIN_PLAUSIBLE_AGE_MS = -50

local NS_PER_MS = 1e6

-- Recent ages whose minimum is the floor lateness is measured from.
M.FLOOR_WINDOW = 32

-- A physical event this much later than the freshest recent events waited
-- behind the main thread: it is never consumed, replayed or answered with
-- output, which macOS may already have overtaken. Every physical-input tap
-- (keymap, tap keys, script control, modifier injector) shares this bound.
M.STALE_PHYSICAL_EVENT_MS = 500

-- The scale the last plausible age was read with, reused for durations.
local _scale = nil
local _ages = {}
local _age_head = 0

--- Reads one event's raw stamp without letting a malformed event raise.
--- @param event userdata|table hs.eventtap event.
--- @return integer|nil stamp Positive raw stamp, or nil.
local function read_stamp(event)
	if event == nil or type(event.timestamp) ~= "function" then return nil end
	local ok, stamp = pcall(event.timestamp, event)
	if not ok or math.type(stamp) ~= "integer" or stamp <= 0 then return nil end
	return stamp
end

--- Reads the host clock in nanoseconds, the domain of the event stamps.
--- @return integer|nil now_ns
local function host_now_ns()
	local native = hs
	local timer = native and native.timer
	if not timer or type(timer.absoluteTime) ~= "function" then return nil end
	local ok, now = pcall(timer.absoluteTime)
	if not ok or type(now) ~= "number" then return nil end
	return now
end

--- Returns how much later than the freshest recent events an event reached the
--- tap that reads it.
--- @param event userdata|table hs.eventtap event.
--- @return number|nil lateness_ms Milliseconds, or nil when no age can be proven.
--- @return integer|nil stamp The event's raw stamp, for duration_ms().
function M.lateness_ms(event)
	local stamp = read_stamp(event)
	if stamp == nil then return nil, nil end
	local now = host_now_ns()
	if now == nil then return nil, stamp end
	-- The smallest plausible age wins: under the wrong scale an Apple silicon
	-- stamp reads as about the whole uptime, and an Intel one as negative.
	local best_age, best_scale = nil, nil
	for _, scale in ipairs(M.SCALES) do
		local age = (now - stamp * scale) / NS_PER_MS
		if age >= M.MIN_PLAUSIBLE_AGE_MS and age <= M.MAX_PLAUSIBLE_AGE_MS
			and (best_age == nil or age < best_age) then
			best_age, best_scale = age, scale
		end
	end
	if best_age == nil then return nil, stamp end
	_scale = best_scale
	_age_head = _age_head % M.FLOOR_WINDOW + 1
	_ages[_age_head] = best_age
	local floor = best_age
	for _, age in pairs(_ages) do
		if age < floor then floor = age end
	end
	return best_age - floor, stamp
end

--- Whether an event reached the tap that reads it so late that macOS may
--- already have delivered it without that tap (kCGEventTapDisabledByTimeout):
--- consuming, replaying or answering it would act on a key the application
--- already has. A late event passes untouched. An event whose age cannot be
--- proven is never judged late.
--- @param event userdata|table hs.eventtap event.
--- @return boolean stale
--- @return number|nil lateness_ms The measured lateness, or nil when unproven.
--- @return integer|nil stamp The event's raw stamp, for duration_ms().
function M.is_stale(event)
	local lateness, stamp = M.lateness_ms(event)
	return lateness ~= nil and lateness >= M.STALE_PHYSICAL_EVENT_MS, lateness, stamp
end

--- Returns the time between two raw stamps read by lateness_ms().
--- @param earlier integer Raw stamp of the earlier event.
--- @param later integer Raw stamp of the later event.
--- @return number|nil duration_ms Milliseconds, or nil before any plausible age.
function M.duration_ms(earlier, later)
	if _scale == nil or math.type(earlier) ~= "integer" or math.type(later) ~= "integer" then
		return nil
	end
	return (later - earlier) * _scale / NS_PER_MS
end

--- Forgets the scale and the ages learned from earlier events; tests use it.
function M.reset()
	_scale = nil
	_ages = {}
	_age_head = 0
end

return M
