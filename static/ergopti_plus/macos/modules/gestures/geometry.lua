--- modules/gestures/geometry.lua

--- ==============================================================================
--- MODULE: Gestures Geometry
--- DESCRIPTION:
--- Pure spatial math for the gesture engine: averaging the finger centroid,
--- classifying a displacement into a direction (horiz/vert/diag), and resolving
--- a finger-count + direction into an action slot name. Extracted from
--- gestures/engine.lua so the touch-frame processor keeps the mutable gesture
--- state while every stateless geometric decision lives in one self-contained,
--- side-effect-free module that is trivial to reason about and unit-test.
---
--- FEATURES & RATIONALE:
--- 1. Stateless by construction — every function takes its inputs as arguments
---    and reads nothing but module-local threshold constants, so it can never be
---    affected by (or corrupt) the live gesture state owned by the engine.
--- 2. Single source of swipe thresholds — SWIPE_MIN / SWIPE_MIN_2 / DIAG_MIN_2
---    live here and the engine reads them back through this module, so the
---    direction classifier and the commit-time threshold check can never drift.
--- 3. One classifier on every driver — computeDir and slotForDir delegate to
---    _shared/lua/gestures/direction.lua, which the Linux evdev decoder uses too:
---    25/65 degree sectors, a Manhattan-total diagonal gate (adx + ady), and the
---    dominant axis below the diagonal minimum. This module keeps the macOS
---    units and the two-finger tuning only.
--- ==============================================================================

local M = {}
local Direction = require("gestures.direction")





-- =========================================
-- =========================================
-- ======= 1/ Constants & Thresholds =======
-- =========================================
-- =========================================

-- Minimum centroid displacement (Manhattan distance) thresholds. These are
-- driver-specific spatial tuning values (not shared cross-driver timings), kept
-- here as the single source of truth so the engine reads them back from this
-- module rather than re-declaring them.
M.SWIPE_MIN   = 1.5    -- 3/4/5 fingers: minimum distance to validate a swipe
M.SWIPE_MIN_2 = 3.0    -- 2 fingers horiz/vert (left to macOS, diagonal only)
M.DIAG_MIN_2  = 5.0    -- 2 fingers: minimum total distance to validate a diagonal





-- ===================================
-- ===================================
-- ======= 2/ Geometry Helpers =======
-- ===================================
-- ===================================

--- Calculates the central point among all current fingers.
--- @param touches table Trackpad touch arrays.
--- @return table X and Y coordinate map.
function M.avgPos(touches)
	local x, y = 0, 0
	if type(touches) ~= "table" or #touches == 0 then return {x=0, y=0} end

	for _, t in ipairs(touches) do
		if type(t) == "table" and type(t.absoluteVector) == "table" and type(t.absoluteVector.position) == "table" then
			x = x + (tonumber(t.absoluteVector.position.x) or 0)
			y = y + (tonumber(t.absoluteVector.position.y) or 0)
		end
	end
	return { x = x / #touches, y = y / #touches }
end

--- Infers the action configuration slot ID given fingers count and direction.
--- @param mf number Number of fingers.
--- @param dir string Direction name (e.g., "horiz", "diag").
--- @param dx number X delta.
--- @param dy number Y delta.
--- @return string|nil The slot string ID.
function M.slotForDir(mf, dir, dx, dy)
	local name = Direction.name(dir, dx, dy)
	return name and Direction.slot(mf, name) or nil
end

--- Derives a general direction from geometric distances.
--- @param dx number X delta.
--- @param dy number Y delta.
--- @param mf number Amount of fingers.
--- @return string|nil Direction string.
function M.computeDir(dx, dy, mf)
	local min = (mf == 2) and M.SWIPE_MIN_2 or M.SWIPE_MIN
	local diag_min = (mf == 2) and M.DIAG_MIN_2 or (min * Direction.DIAGONAL_MINIMUM_FACTOR)
	return Direction.axis(dx, dy, min, diag_min)
end

return M
