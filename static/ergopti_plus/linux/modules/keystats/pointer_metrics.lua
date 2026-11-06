--- modules/keystats/pointer_metrics.lua

--- ==============================================================================
--- MODULE: Pointer Metrics (Linux)
--- DESCRIPTION:
--- Turns the evdev reports of the observed pointers into the three mouse
--- columns of events_typing: clicks, wheel turns and distance travelled. macOS
--- fills the same columns from its event tap and a cursor poll; Linux had the
--- columns and wrote zeroes.
---
--- FEATURES & RATIONALE:
--- 1. Clicks are left and right button presses, the two macOS counts. A
---    touchpad tap-to-click is synthesised above the kernel and never reaches
---    evdev as a button, so it is not counted; a finger contact (BTN_TOUCH) is
---    a touch, not a click.
--- 2. A wheel turn is one REL_WHEEL or REL_HWHEEL report. The high-resolution
---    axes repeat the same turn in finer units and would count it twice.
--- 3. Distance is the length of each evdev frame's REL_X/REL_Y vector, summed:
---    the axes of one movement arrive as separate reports closed by SYN_REPORT.
---    It is in device units, before the desktop's pointer acceleration. Linux
---    has no cursor position to poll under Wayland, so the screen pixels macOS
---    measures cannot be read here.
--- ==============================================================================

local M = {}

local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")

-- The buttons counted as a click, as on macOS (leftMouseDown, rightMouseDown)
local CLICK_BUTTONS = { [EvdevCodes.BTN_LEFT] = true, [EvdevCodes.BTN_RIGHT] = true }

-- The wheel axes counted as one scroll per report
local SCROLL_AXES = { [InputEvent.REL_WHEEL] = true, [InputEvent.REL_HWHEEL] = true }

-- The kinds the keyboard hook reports a pointer event as
M.KIND_PRESS  = "press"
M.KIND_MOTION = "motion"
M.KIND_FRAME  = "frame"
M.KIND_RESET  = "reset"
M.KIND_DROPPED = "dropped"

-- The kinds above, for validation
local KINDS = { [M.KIND_PRESS] = true, [M.KIND_MOTION] = true, [M.KIND_FRAME] = true,
	[M.KIND_RESET] = true, [M.KIND_DROPPED] = true }




-- ===============================
-- ===============================
-- ======= 1/ Tracker ============
-- ===============================
-- ===============================

--- Creates a tracker of pointer streams. Each device keeps its own open frame
--- until SYN_REPORT; queue loss discards the frame through the next SYN_REPORT.
--- @return table tracker { observe(kind, code, value) }
function M.new()
	local tracker = {}
	local frames, dropping, default_source = {}, {}, {}
	local fractions, fraction_database, fraction_device = {}, nil, nil

	--- A new storage owner must not inherit another database's remainder.
	function tracker.bind_fractions(database, device)
		if database ~= fraction_database or device ~= fraction_device then
			fractions = {}
			fraction_database, fraction_device = database, device
		end
	end

	--- Copies committed sub-unit distance by day and application. The flush
	--- owner publishes a successor only after the matching SQLite COMMIT.
	function tracker.snapshot_fractions()
		local copy = {}
		for date, apps in pairs(fractions) do
			copy[date] = {}
			for app, value in pairs(apps) do copy[date][app] = value end
		end
		return copy
	end

	--- Discard empty entries without losing a remainder for a delayed old day.
	function tracker.commit_fractions(value)
		for date, apps in pairs(value) do
			for app, remainder in pairs(apps) do
				if remainder == 0 then apps[app] = nil end
			end
			if next(apps) == nil then value[date] = nil end
		end
		fractions = value
	end

	--- Forgets uncommitted movement without admitting a dropped packet.
	function tracker.discard_frames()
		frames = {}
	end

	--- Observes one pointer report and returns what it adds to the metrics.
	--- @param kind string "press", "motion", "frame", "dropped" or "reset".
	--- @param code integer evdev code of the report.
	--- @param value integer evdev value of the report.
	--- @param source any|nil Identity of the pointer producing this frame.
	--- @return table|nil delta { clicks, scrolls, distance } or nil when it adds nothing.
	function tracker.observe(kind, code, value, source)
		assert(KINDS[kind], "unknown pointer event kind: " .. tostring(kind))
		local key = source or default_source
		if kind == M.KIND_RESET then
			frames[key], dropping[key] = nil, nil
			return nil
		end
		if kind == M.KIND_DROPPED then
			frames[key], dropping[key] = nil, true
			return nil
		end
		if dropping[key] then
			if kind == M.KIND_FRAME then dropping[key] = nil end
			return nil
		end
		if kind == M.KIND_PRESS then
			if CLICK_BUTTONS[code] then return { clicks = 1, scrolls = 0, distance = 0 } end
			return nil
		end
		if kind == M.KIND_MOTION then
			if SCROLL_AXES[code] then return { clicks = 0, scrolls = 1, distance = 0 } end
			assert(type(value) == "number", "a pointer motion report needs its evdev value")
			if code == InputEvent.REL_X or code == InputEvent.REL_Y then
				local frame = frames[key] or { dx = 0, dy = 0 }
				frames[key] = frame
				if code == InputEvent.REL_X then frame.dx = frame.dx + value else frame.dy = frame.dy + value end
			end
			return nil
		end
		local frame = frames[key]
		frames[key] = nil
		if not frame or (frame.dx == 0 and frame.dy == 0) then return nil end
		local distance = math.sqrt(frame.dx * frame.dx + frame.dy * frame.dy)
		return { clicks = 0, scrolls = 0, distance = distance }
	end

	return tracker
end

return M
