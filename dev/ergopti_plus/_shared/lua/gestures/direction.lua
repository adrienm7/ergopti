--- _shared/lua/gestures/direction.lua

--- ==============================================================================
--- MODULE: Gesture Direction — Shared Lua Implementation
--- DESCRIPTION:
--- Turns a swipe displacement into the axis it travelled on, the direction
--- name a configuration slot carries, and the slot itself. The macOS geometry
--- (modules/gestures/geometry.lua) and the Linux evdev decoder
--- (modules/gestures/mt_decoder.lua) both classify through this module; they
--- differ only in the unit their displacement is measured in, so each passes
--- its own swipe minimum and diagonal minimum.
---
--- FEATURES & RATIONALE:
--- 1. Stricter sectors for the straight axes: within AXIS_MAX_DEGREES of an
---    axis a swipe is straight, so a slightly tilted horizontal swipe never
---    locks a diagonal. Both boundaries are inclusive of the straight axis.
--- 2. Manhattan travel: the swipe minimum and the diagonal minimum are
---    measured on |dx| + |dy|, so a 45 degree swipe is detectable at the same
---    travel as a straight one rather than needing twice as much.
--- 3. A diagonal needs more travel than a straight swipe; below its minimum a
---    swipe in the diagonal sector falls back to its dominant axis.
--- 4. Screen convention on both drivers: y grows downward, so a positive dy is
---    "down". A diagonal is named horizontal part first (right_down), the way
---    _shared/modules/actions/actions.toml declares every swipe slot.
---
--- Pinned by _shared/tests/corpus/gestures/direction_vectors.json, replayed by
--- both drivers in normalised units (a swipe minimum of 1).
--- ==============================================================================

local M = {}

-- LuaJIT's math.atan takes one argument and silently ignores a second, so the
-- two-argument arc tangent is math.atan2 there and math.atan on Lua 5.4.
local atan2 = math.atan2 or math.atan




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Within this angle of the horizontal axis a swipe is horizontal, and within
-- this angle of the vertical axis it is vertical; between the two it may be a
-- diagonal.
M.AXIS_MAX_DEGREES = 25

-- The diagonal minimum of a driver that has no finger-specific tuning, as a
-- multiple of its swipe minimum.
M.DIAGONAL_MINIMUM_FACTOR = 1.5




-- =============================================
-- =============================================
-- ======= 2/ Public API =======================
-- =============================================
-- =============================================

--- Classifies a displacement into the axis the swipe travelled on.
--- @param dx number Horizontal displacement, positive rightward.
--- @param dy number Vertical displacement, positive downward.
--- @param minimum number Least Manhattan travel that is a swipe at all.
--- @param diagonal_minimum number Least Manhattan travel that may be a diagonal.
--- @return string|nil axis "horiz", "vert" or "diag"; nil below the minimum.
function M.axis(dx, dy, minimum, diagonal_minimum)
	assert(type(dx) == "number" and type(dy) == "number", "a displacement needs numeric dx and dy")
	assert(type(minimum) == "number" and minimum > 0, "the swipe minimum must be a positive number")
	assert(type(diagonal_minimum) == "number" and diagonal_minimum >= minimum,
		"the diagonal minimum must be a number no smaller than the swipe minimum")
	local adx, ady = math.abs(dx), math.abs(dy)
	local dist = adx + ady
	if dist < minimum then return nil end

	local angle = math.deg(atan2(ady, adx))
	if angle >= 90 - M.AXIS_MAX_DEGREES then return "vert" end
	if angle <= M.AXIS_MAX_DEGREES then return "horiz" end
	if dist >= diagonal_minimum then return "diag" end
	-- Not enough travel for a diagonal: the dominant axis wins.
	return (adx >= ady) and "horiz" or "vert"
end

--- Names the direction of a displacement already classified on an axis.
--- @param axis string "horiz", "vert" or "diag".
--- @param dx number Horizontal displacement, positive rightward.
--- @param dy number Vertical displacement, positive downward.
--- @return string|nil name right, left, down, up or a horizontal_vertical diagonal.
function M.name(axis, dx, dy)
	if axis ~= "horiz" and axis ~= "vert" and axis ~= "diag" then return nil end
	local horizontal = dx > 0 and "right" or "left"
	local vertical = dy > 0 and "down" or "up"
	if axis == "horiz" then return horizontal end
	if axis == "vert" then return vertical end
	return horizontal .. "_" .. vertical
end

--- Classifies a displacement straight to its direction name.
--- @param dx number Horizontal displacement, positive rightward.
--- @param dy number Vertical displacement, positive downward.
--- @param minimum number Least Manhattan travel that is a swipe at all.
--- @param diagonal_minimum number Least Manhattan travel that may be a diagonal.
--- @return string|nil name The direction, or nil below the minimum.
function M.classify(dx, dy, minimum, diagonal_minimum)
	local axis = M.axis(dx, dy, minimum, diagonal_minimum)
	return axis and M.name(axis, dx, dy) or nil
end

--- The configuration slot of a swipe.
--- @param fingers number Finger count of the gesture.
--- @param name string Direction name from M.name or M.classify.
--- @return string slot swipe_<fingers>_<name>.
function M.slot(fingers, name)
	assert(type(fingers) == "number" and type(name) == "string", "a swipe slot needs fingers and a direction")
	return "swipe_" .. tostring(fingers) .. "_" .. name
end

return M
