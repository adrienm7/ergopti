--- modules/keystats/pointer_events.lua

--- ==============================================================================
--- MODULE: Pointer Events (Linux)
--- DESCRIPTION:
--- Turns the evdev reports of the observed pointers into the rows Windows
--- writes to events_mouse (keystats_mouse.ahk): one mouse_click per button
--- press and one mouse_scroll per burst of wheel turns.
---
--- FEATURES & RATIONALE:
--- 1. A click names its button (left, right, middle), as on Windows.
--- 2. Wheel turns are coalesced into bursts closed by a silence of timings
---    [keystats] mouse_scroll_burst_gap_ms, the Windows SCROLL_BURST_GAP_MS. A
---    burst carries its direction (up, down, horizontal), its notches, its
---    duration and its notches per second.
--- 3. No coordinates: Wayland gives no cursor position to read, so the x/y
---    fields Windows adds are absent. Drags and the idle park need the cursor
---    position too and are not produced here.
--- 4. Every function takes `now_ms`, the caller's monotonic time, and returns
---    the events it closed, in order: { kind, meta }.
--- ==============================================================================

local M = {}

local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")

-- The buttons a click names
local BUTTON_NAMES = {
	[EvdevCodes.BTN_LEFT]   = "left",
	[EvdevCodes.BTN_RIGHT]  = "right",
	[EvdevCodes.BTN_MIDDLE] = "middle",
}

-- Velocity is reported to two decimals, as on Windows
local VELOCITY_SCALE = 100

-- Milliseconds per second, for the notches-per-second velocity
local MS_PER_SECOND = 1000




-- ===============================
-- ===============================
-- ======= 1/ Tracker ============
-- ===============================
-- ===============================

--- A fresh tracker.
--- @param opts table { burst_gap_ms } from the shared timings.
--- @return table tracker { observe(kind, code, value, now_ms), tick(now_ms) }
function M.new(opts)
	if type(opts) ~= "table" or type(opts.burst_gap_ms) ~= "number" or opts.burst_gap_ms <= 0 then
		error("pointer_events.new requires a positive burst_gap_ms", 2)
	end
	local gap_ms = opts.burst_gap_ms
	local tracker = {}
	local burst = nil

	local function close_burst(events)
		local duration_ms = math.max(0, burst.last_ms - burst.start_ms)
		local horizontal = burst.h_ticks ~= 0
		local total = horizontal and math.abs(burst.h_ticks) or math.abs(burst.ticks)
		local velocity = duration_ms > 0
			and math.floor(total / (duration_ms / MS_PER_SECOND) * VELOCITY_SCALE + 0.5) / VELOCITY_SCALE or 0
		events[#events + 1] = { kind = "mouse_scroll", meta = {
			direction = horizontal and "horizontal" or (burst.ticks > 0 and "up" or "down"),
			ticks = total, velocity = velocity, duration_ms = duration_ms,
		} }
		burst = nil
		return events
	end

	--- Observes one pointer report.
	--- @param kind string "press", "motion" or "frame" (the keyboard hook's kinds).
	--- @param code integer evdev code.
	--- @param value integer evdev value.
	--- @param now_ms number
	--- @return table events
	function tracker.observe(kind, code, value, now_ms)
		assert(type(now_ms) == "number", "pointer_events needs a time")
		local events = {}
		if burst and now_ms - burst.last_ms > gap_ms then close_burst(events) end
		if kind == "press" and BUTTON_NAMES[code] then
			events[#events + 1] = { kind = "mouse_click", meta = { button = BUTTON_NAMES[code] } }
		elseif kind == "motion" and (code == InputEvent.REL_WHEEL or code == InputEvent.REL_HWHEEL) then
			assert(type(value) == "number", "a wheel report needs its evdev value")
			burst = burst or { start_ms = now_ms, ticks = 0, h_ticks = 0 }
			if code == InputEvent.REL_WHEEL then burst.ticks = burst.ticks + value
			else burst.h_ticks = burst.h_ticks + value end
			burst.last_ms = now_ms
		end
		return events
	end

	--- Closes a burst whose silence has passed.
	--- @param now_ms number
	--- @return table events
	function tracker.tick(now_ms)
		assert(type(now_ms) == "number", "pointer_events needs a time")
		if burst and now_ms - burst.last_ms > gap_ms then return close_burst({}) end
		return {}
	end

	return tracker
end

return M
