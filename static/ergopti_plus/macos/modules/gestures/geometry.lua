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
--- 3. Manhattan-total diagonal gate — computeDir locks a diagonal on the total
---    travel (adx + ady) rather than on each axis independently, so a 45 degree
---    swipe is detectable at the same distance as a straight one.
--- ==============================================================================

local M = {}





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
	local prefix = "swipe_" .. tostring(mf) .. "_"
	if dir == "horiz" then
		return prefix .. (dx > 0 and "right" or "left")
	elseif dir == "vert" then
		return prefix .. (dy > 0 and "down" or "up")
	elseif dir == "diag" then
		if dx > 0 then
			return prefix .. (dy > 0 and "right_down" or "right_up")
		else
			return prefix .. (dy > 0 and "left_down" or "left_up")
		end
	end
	return nil
end

--- Derives a general direction from geometric distances.
--- @param dx number X delta.
--- @param dy number Y delta.
--- @param mf number Amount of fingers.
--- @return string|nil Direction string.
function M.computeDir(dx, dy, mf)
	local adx  = math.abs(dx)
	local ady  = math.abs(dy)
	local dist = adx + ady
	local min  = (mf == 2) and M.SWIPE_MIN_2 or M.SWIPE_MIN

	if dist < min then return nil end

	-- Stricter angles for primary axes to avoid accidental diagonal lock
	-- Horizontal: 0-25 degrees (atan dy/dx)
	-- Vertical: 65-90 degrees
	-- Diagonal: 25-65 degrees
	local angle = math.deg(math.atan(ady, adx))

	if angle >= 65 then
		return "vert"
	elseif angle <= 25 then
		return "horiz"
	else
		-- Lock diagonal only when total Manhattan distance (adx+ady) meets the threshold.
		-- The previous guard required each axis to independently exceed diagMin, which
		-- doubled the required travel (e.g. 10 units for diagMin=5, not 5). Using the
		-- already-computed `dist` matches the "minimum total distance" intent and makes
		-- 45° diagonals detectable at the same distance as straight swipes.
		local diagMin = (mf == 2) and M.DIAG_MIN_2 or (min * 1.5)
		if dist >= diagMin then return "diag" end

		-- Fallback to dominant axis if not enough "diagonal-ness"
		return (adx >= ady) and "horiz" or "vert"
	end
end

return M
