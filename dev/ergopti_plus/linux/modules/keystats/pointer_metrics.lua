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

-- The kinds above, for validation
local KINDS = { [M.KIND_PRESS] = true, [M.KIND_MOTION] = true, [M.KIND_FRAME] = true }




-- ===============================
-- ===============================
-- ======= 1/ Tracker ============
-- ===============================
-- ===============================

--- Creates a tracker of one pointer stream. It keeps the open frame's movement
--- until the frame's SYN_REPORT, so a movement is measured once, whole.
--- @return table tracker { observe(kind, code, value) }
function M.new()
	local tracker = {}
	local dx, dy = 0, 0

	--- Observes one pointer report and returns what it adds to the metrics.
	--- @param kind string "press" (a button pressed), "motion" (an EV_REL report) or "frame" (SYN_REPORT).
	--- @param code integer evdev code of the report.
	--- @param value integer evdev value of the report.
	--- @return table|nil delta { clicks, scrolls, distance } or nil when it adds nothing.
	function tracker.observe(kind, code, value)
		assert(KINDS[kind], "unknown pointer event kind: " .. tostring(kind))
		if kind == M.KIND_PRESS then
			if CLICK_BUTTONS[code] then return { clicks = 1, scrolls = 0, distance = 0 } end
			return nil
		end
		if kind == M.KIND_MOTION then
			if SCROLL_AXES[code] then return { clicks = 0, scrolls = 1, distance = 0 } end
			assert(type(value) == "number", "a pointer motion report needs its evdev value")
			if code == InputEvent.REL_X then dx = dx + value elseif code == InputEvent.REL_Y then dy = dy + value end
			return nil
		end
		if dx == 0 and dy == 0 then return nil end
		local distance = math.sqrt(dx * dx + dy * dy)
		dx, dy = 0, 0
		return { clicks = 0, scrolls = 0, distance = distance }
	end

	return tracker
end

return M
