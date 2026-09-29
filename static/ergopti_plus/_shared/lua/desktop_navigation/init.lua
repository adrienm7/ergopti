--- _shared/lua/desktop_navigation/init.lua

--- ==============================================================================
--- MODULE: Desktop Navigation
--- DESCRIPTION:
--- The index maths of the previous/next desktop actions, for the macOS and
--- Linux drivers: which desktop one step lands on, with or without wrapping at
--- the edges. Windows ports the same rule in
--- windows/modules/gestures/virtual_desktops.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller reads the current position and the desktop count from
---    its operating system and passes them, so the rule is testable without a
---    desktop session.
--- 2. One rule, pinned by _shared/tests/corpus/desktop_navigation/vectors.json,
---    which the three driver suites replay.
--- 3. Fail fast: a position outside the count is a failed read of the
---    operating system, never a position to clamp, so it raises instead of
---    switching somewhere the user did not ask for.
--- ==============================================================================

local M = {}

--- The two directions a step can take.
M.PREVIOUS = "prev"
M.NEXT = "next"

local STEP = { [M.PREVIOUS] = -1, [M.NEXT] = 1 }

--- @param value any
--- @return boolean True for a whole number (LuaJIT has no math.type).
local function is_whole(value)
	return type(value) == "number" and value == math.floor(value)
end

--- Rejects an input the rule cannot place.
--- @param index any 0-based current position.
--- @param count any Number of desktops.
--- @param direction any M.PREVIOUS or M.NEXT.
--- @param wrap any Whether the step wraps at the edges.
local function validate(index, count, direction, wrap)
	if not is_whole(count) or count < 1 then
		error("desktop_navigation: the desktop count must be a whole number >= 1, got "
			.. tostring(count), 3)
	end
	if not is_whole(index) or index < 0 or index >= count then
		error(string.format("desktop_navigation: index %s is outside the %d desktop(s)",
			tostring(index), count), 3)
	end
	if STEP[direction] == nil then
		error("desktop_navigation: unknown direction '" .. tostring(direction) .. "'", 3)
	end
	if type(wrap) ~= "boolean" then
		error("desktop_navigation: wrap must be a boolean, got " .. type(wrap), 3)
	end
end

--- The desktop one step lands on.
--- @param index integer 0-based position of the current desktop.
--- @param count integer Number of desktops (at least 1).
--- @param direction string M.PREVIOUS or M.NEXT.
--- @param wrap boolean True to go to the other end from an edge.
--- @return integer target 0-based position; equal to index when the step stays.
function M.target(index, count, direction, wrap)
	validate(index, count, direction, wrap)
	local target = index + STEP[direction]
	if target >= 0 and target < count then return target end
	if not wrap then return index end
	return (target + count) % count
end

--- The signed number of single steps from the current desktop to the target:
--- what a driver that can only press "one desktop left/right" repeats.
--- @param index integer 0-based position of the current desktop.
--- @param count integer Number of desktops (at least 1).
--- @param direction string M.PREVIOUS or M.NEXT.
--- @param wrap boolean True to go to the other end from an edge.
--- @return integer steps Negative towards the first desktop, 0 to stay.
function M.steps(index, count, direction, wrap)
	return M.target(index, count, direction, wrap) - index
end

return M
