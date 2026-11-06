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
--- 3. Distance is in screen pixels, the unit Windows (cursor positions) and
---    macOS (absolute position polls) store. An evdev frame that moved the
---    pointer triggers a read of the cursor position, at most once every
---    POSITION_SAMPLE_MS, and the straight line from the previous read is
---    credited. The REL_X/REL_Y device units are never credited: they precede
---    the desktop's acceleration and summed beside pixels they would make the
---    column mean two things. Without a cursor position (Wayland grants no
---    global one) the distance is not measured; availability() says why.
--- ==============================================================================

local M = {}

local EvdevCodes = require("infra.evdev_codes")
local InputEvent = require("infra.input_event")

-- The buttons counted as a click, as on macOS (leftMouseDown, rightMouseDown)
local CLICK_BUTTONS = { [EvdevCodes.BTN_LEFT] = true, [EvdevCodes.BTN_RIGHT] = true }

-- The wheel axes counted as one scroll per report
local SCROLL_AXES = { [InputEvent.REL_WHEEL] = true, [InputEvent.REL_HWHEEL] = true }

-- Shortest interval between two cursor reads during a movement: a 60 Hz frame,
-- the resolution at which a straight line between reads stays the travelled path.
M.POSITION_SAMPLE_MS = 16

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
	-- The cursor position source: read() -> x, y | nil, reason; clock() -> ms.
	local position = { read = nil, clock = nil, x = nil, y = nil, at = nil, reason = nil }

	--- Binds the screen-pixel position source, or unbinds it with the reason
	--- the distance cannot be measured.
	--- @param read function|nil Returns x, y in screen pixels, or nil, reason.
	--- @param clock function|nil Monotonic milliseconds.
	--- @param reason string|nil Why there is no source when read is nil.
	function tracker.bind_position(read, clock, reason)
		assert(read == nil or (type(read) == "function" and type(clock) == "function"),
			"a pointer position source needs its clock")
		position = { read = read, clock = clock, x = nil, y = nil, at = nil, reason = read == nil and reason or nil }
	end

	--- Whether the distance is measured, and in which unit.
	--- @return table { measured = boolean, unit = "px"|nil, reason = string|nil }
	function tracker.availability()
		if position.read then return { measured = true, unit = "px" } end
		return { measured = false, reason = position.reason or "no cursor position source" }
	end

	--- The screen distance since the previous cursor read, when one is due.
	local function travelled()
		if not position.read then return 0 end
		local now = position.clock()
		if position.at and now - position.at < M.POSITION_SAMPLE_MS then return 0 end
		local x, y = position.read()
		position.at = now
		if type(x) ~= "number" or type(y) ~= "number" then
			-- A refused read seeds afresh: no line is drawn across the gap.
			position.x, position.y = nil, nil
			return 0
		end
		local distance = 0
		if position.x then
			local dx, dy = x - position.x, y - position.y
			distance = math.sqrt(dx * dx + dy * dy)
		end
		position.x, position.y = x, y
		return distance
	end

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

	--- Forgets the cursor position: the next read seeds afresh, so travel made
	--- while collection is closed is never credited.
	function tracker.forget_position()
		position.x, position.y, position.at = nil, nil, nil
	end

	--- Reads the cursor now without crediting the travel since the previous
	--- read: a focus change starts the next application's path where it gets
	--- the pointer, as discarding the open frame did for device units.
	function tracker.reseed()
		if not position.read then return end
		position.at = position.clock()
		local x, y = position.read()
		if type(x) == "number" and type(y) == "number" then position.x, position.y = x, y
		else position.x, position.y = nil, nil end
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
		local distance = travelled()
		if distance <= 0 then return nil end
		return { clicks = 0, scrolls = 0, distance = distance }
	end

	return tracker
end

return M
