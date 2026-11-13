--- _shared/gestures/engine/incremental.lua

--- ==============================================================================
--- MODULE: Incremental Swipe Steps — Shared Lua Implementation
--- DESCRIPTION:
--- How many actions an incremental swipe has earned over the distance it
--- travelled, and how far it must come back before it counts as a reversal.
--- The macOS engine (modules/gestures/engine.lua) and the Linux gesture manager
--- (modules/gestures/manager.lua) both count through this module, in
--- millimetres of travel on the pad: the macOS trackpad reports them, and the
--- Linux decoder converts evdev units with the resolution the device reports.
---
--- FEATURES & RATIONALE:
--- 1. The first action fires once the swipe has travelled FIRST_STEP, each
---    further one after one more step (the slot's sensitivity). A short
---    deliberate swipe still fires once, while a large step keeps a normal
---    swipe to exactly one action. A step smaller than FIRST_STEP fires its
---    first action after one step.
--- 2. The count only grows within one swipe: an engine holds the actions it
---    fired when the distance shrinks, so drift never takes one back or earns
---    it twice; a real reversal is measured from the last fire.
--- ==============================================================================

local M = {}

-- Travel before the first action of an incremental swipe.
M.FIRST_STEP = 4.0

-- Bound on the synchronous work of a single touch frame. A normal full swipe
-- travels about 15 to 45 units, so even at the smallest supported step of 1
-- it remains well below this guard. An implausible sensor jump is rejected,
-- not truncated.
M.MAX_ACTIONS_PER_FRAME = 100

--- Counts the incremental actions a swipe has earned over a distance.
--- @param distance number Absolute travel along the swipe axis.
--- @param step number Distance per action after the first (the sensitivity).
--- @return integer steps
function M.steps(distance, step)
	if type(distance) ~= "number" or distance ~= distance or distance < 0 or distance == math.huge then
		error("incremental distance must be a finite non-negative number")
	end
	if type(step) ~= "number" or step ~= step or step <= 0 or step == math.huge then
		error("incremental step must be a finite positive number")
	end
	local first = math.min(M.FIRST_STEP, step)
	if distance < first then return 0 end
	local count = (distance - first) / step
	if count == math.huge then error("incremental action count is not finite") end
	return 1 + math.floor(count)
end

--- Distance a swipe must come back from its last action before it counts as a
--- reversal: half the first step, so lift-off drift neither reverses a swipe
--- nor, through the rebase, fires the opposite action.
--- @param step number Distance per action after the first (the sensitivity).
--- @param floor number Smallest reversal distance the engine accepts.
--- @return number distance
function M.reverse_min(step, floor)
	return math.max(floor, math.min(M.FIRST_STEP, step) / 2)
end

return M
