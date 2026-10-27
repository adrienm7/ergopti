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

-- Travel a two-finger contact set may cover while more fingers can still land
-- on it (see Direction.LANDING_TRAVEL_FACTOR); past it the pair is scrolling.
M.LANDING_TRAVEL_MAX = M.SWIPE_MIN_2 * Direction.LANDING_TRAVEL_FACTOR

-- Least share of the centroid's travel along the swipe axis that EVERY contact
-- of a three-or-more-finger gesture must cover itself, in the same direction.
-- Two scrolling fingers beside a resting thumb move the centroid two thirds of
-- their travel while the thumb covers none, which this share rejects.
M.COHESION_MIN_SHARE = 0.5





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

--- Lists the contact positions of one frame, ranked across the swipe axis.
--- The touch device numbers its contacts, but ranking by the coordinate across
--- the axis pairs the same finger in two frames without trusting that number:
--- fingers swiping vertically sit side by side horizontally, and the reverse.
--- @param touches table Trackpad touch arrays.
--- @param axis string "horiz" or "vert".
--- @return table Array of { x, y }, ordered across the axis.
function M.contactsAcross(touches, axis)
	local across = (axis == "horiz") and "y" or "x"
	local contacts = {}
	for _, t in ipairs(touches) do
		local p = type(t) == "table" and type(t.absoluteVector) == "table"
			and t.absoluteVector.position or nil
		if type(p) == "table" then
			contacts[#contacts + 1] = { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0 }
		end
	end
	table.sort(contacts, function(a, b) return a[across] < b[across] end)
	return contacts
end

--- Tells whether every contact travelled along the axis with the centroid.
--- @param origin table Contacts at the start, from contactsAcross().
--- @param current table The same contacts now, from contactsAcross().
--- @param axis string "horiz" or "vert".
--- @return boolean together True when each contact covered at least
---   COHESION_MIN_SHARE of the centroid's travel, in its direction.
function M.movedTogether(origin, current, axis)
	if type(origin) ~= "table" or type(current) ~= "table"
		or #origin == 0 or #origin ~= #current then
		return false
	end
	local along = (axis == "horiz") and "x" or "y"
	local total = 0
	for i = 1, #origin do total = total + (current[i][along] - origin[i][along]) end
	total = total / #origin
	if total == 0 then return false end
	local sign = total > 0 and 1 or -1
	local least = M.COHESION_MIN_SHARE * math.abs(total)
	for i = 1, #origin do
		if (current[i][along] - origin[i][along]) * sign < least then return false end
	end
	return true
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
