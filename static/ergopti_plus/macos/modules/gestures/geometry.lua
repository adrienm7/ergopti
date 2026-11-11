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
local Incremental = require("gestures.incremental")
local ContactJoin = require("gestures.contact_join")





-- =========================================
-- =========================================
-- ======= 1/ Constants & Thresholds =======
-- =========================================
-- =========================================

-- Minimum centroid displacement (Manhattan distance) thresholds, from the
-- shared timings registry the Linux tracker reads too ([gestures] *_minimum_mm,
-- GSD-3); the engine reads them back from this module rather than re-declaring them.
local Timings = require("infra.timings")
local MINIMUMS = {
	swipe_minimum_mm = Timings.count("gestures", "swipe_minimum_mm"),
	pair_swipe_minimum_mm = Timings.count("gestures", "pair_swipe_minimum_mm"),
	pair_diagonal_minimum_mm = Timings.count("gestures", "pair_diagonal_minimum_mm"),
}
M.SWIPE_MIN, M.SWIPE_DIAG_MIN = Direction.minimums_mm(3, MINIMUMS) -- 3/4/5 fingers: minimum distance to validate a swipe
-- 2 fingers: horiz/vert (left to macOS, diagonal only), and the total distance of a diagonal
M.SWIPE_MIN_2, M.DIAG_MIN_2 = Direction.minimums_mm(2, MINIMUMS)

-- Incremental mode: the shared step rule (_shared/lua/gestures/incremental.lua),
-- the same one the Linux gesture manager counts with.
M.INCREMENTAL_FIRST_STEP = Incremental.FIRST_STEP
M.MAX_INCREMENTAL_ACTIONS_PER_FRAME = Incremental.MAX_ACTIONS_PER_FRAME

-- Least share of the centroid's travel along the swipe axis that EVERY contact
-- of a three-or-more-finger gesture must cover itself, in the same direction.
-- Two scrolling fingers beside a resting thumb move the centroid two thirds of
-- their travel while the thumb covers none, which this share rejects.
M.COHESION_MIN_SHARE = 0.3





-- ===================================
-- ===================================
-- ======= 2/ Geometry Helpers =======
-- ===================================
-- ===================================

--- Rejects a frame whose centroid cannot be computed from every contact.
--- @param touches table Trackpad touch array.
--- @return boolean valid
function M.validPositions(touches)
	for _, touch in ipairs(touches) do
		local position = type(touch) == "table" and type(touch.absoluteVector) == "table"
			and touch.absoluteVector.position or nil
		if type(position) ~= "table" then return false end
		for _, axis in ipairs({ "x", "y" }) do
			local value = position[axis]
			if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
				return false
			end
		end
	end
	return true
end
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

--- Tells why the contacts of one frame cannot be three fingers of one hand:
--- a far or oversized third contact, a resting thumb beside a pair (shared
--- rule, _shared/lua/gestures/contact_join.lua; the trackpad reports
--- millimetres). Any other count is not judged.
--- @param touches table Trackpad touch arrays.
--- @return string|nil reason "far" or "oversized", nil when admitted.
--- @return string|nil detail The measured value, for the log.
function M.joinRefusal(touches)
	local contacts = {}
	for _, t in ipairs(type(touches) == "table" and touches or {}) do
		local p = type(t) == "table" and type(t.absoluteVector) == "table"
			and t.absoluteVector.position or nil
		if type(p) ~= "table" then return nil end
		contacts[#contacts + 1] = { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0,
			major = tonumber(t.majorAxis) }
	end
	return ContactJoin.refusal(contacts)
end

--- Describes each contact of one frame for the log: its position and its
--- major axis, the two values a far or oversized contact (a resting thumb
--- joining a pair) can be told apart by. Ordered left to right.
--- @param touches table Trackpad touch arrays.
--- @return string One "(x, y major m)" group per contact, "none" when empty.
function M.describeContacts(touches)
	local contacts = {}
	for _, t in ipairs(type(touches) == "table" and touches or {}) do
		local p = type(t) == "table" and type(t.absoluteVector) == "table"
			and t.absoluteVector.position or nil
		if type(p) == "table" then
			contacts[#contacts + 1] = { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0,
				major = tonumber(t.majorAxis) }
		end
	end
	if #contacts == 0 then return "none" end
	table.sort(contacts, function(a, b) return a.x < b.x end)
	local parts = {}
	for i, c in ipairs(contacts) do
		parts[i] = string.format("(%.1f, %.1f major %s)", c.x, c.y,
			c.major and string.format("%.2f", c.major) or "?")
	end
	return table.concat(parts, " ")
end

--- Tells whether every contact travelled along the axis with the centroid.
--- @param origin table Contacts at the start, from contactsAcross().
--- @param current table The same contacts now, from contactsAcross().
--- @param axis string "horiz" or "vert".
--- @return boolean together True when each contact covered at least
---   COHESION_MIN_SHARE of the centroid's travel, in its direction.
--- @return number|nil share The least share any contact covered (0 when the
---   contacts cannot be paired, nil while the centroid has not travelled).
function M.movedTogether(origin, current, axis)
	if type(origin) ~= "table" or type(current) ~= "table"
		or #origin == 0 or #origin ~= #current then
		return false, 0
	end
	local along = (axis == "horiz") and "x" or "y"
	local total = 0
	for i = 1, #origin do total = total + (current[i][along] - origin[i][along]) end
	total = total / #origin
	if total == 0 then return false, nil end
	local sign = total > 0 and 1 or -1
	local share = math.huge
	for i = 1, #origin do
		share = math.min(share, (current[i][along] - origin[i][along]) * sign / math.abs(total))
	end
	return share >= M.COHESION_MIN_SHARE, share
end

M.incrementalSteps = Incremental.steps
M.incrementalReverseMin = Incremental.reverse_min

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
	local diag_min = (mf == 2) and M.DIAG_MIN_2 or M.SWIPE_DIAG_MIN
	return Direction.axis(dx, dy, min, diag_min)
end

--- The direction a moving swipe locks on. A swipe of three fingers or more in
--- the diagonal sector waits for the diagonal minimum (Direction.decided_axis)
--- instead of locking the dominant straight axis computeDir names there, which
--- dropped a slow diagonal at its end as « not the locked direction ». A pair
--- keeps computeDir: its lock is what makes it a scroll at once.
--- @param dx number X delta.
--- @param dy number Y delta.
--- @param mf number Amount of fingers.
--- @return string|nil Direction string, nil while undecided.
function M.lockDir(dx, dy, mf)
	if mf == 2 then return M.computeDir(dx, dy, mf) end
	return Direction.decided_axis(dx, dy, M.SWIPE_MIN, M.SWIPE_DIAG_MIN)
end

return M
