--- modules/gestures/incremental_tracker.lua

--- ==============================================================================
--- MODULE: Incremental Swipe Tracker (Linux)
--- DESCRIPTION:
--- Fires an incremental slot's action while the fingers move, one action per
--- step of travel, as the macOS engine does: three fingers moving across the
--- pad step through tabs one by one instead of switching one tab per swipe.
---
--- FEATURES & RATIONALE:
--- 1. Millimetres, as on macOS: the decoder's travel is in device units, and
---    the touchpad's own resolution (units per millimetre) converts it, so one
---    sensitivity means the same distance on both systems.
--- 2. The shared step rule (_shared/lua/gestures/incremental.lua): the first
---    action after FIRST_STEP, each further one after one more step; a
---    shrinking distance keeps the actions fired.
--- 3. Reversal from the last fire: coming back half a first step rebases the
---    swipe there, so the opposite direction starts fresh, as on macOS.
--- 4. The mode and step are those of the slot that answers: an axis slot
---    (swipe_N_horiz) standing in for an unbound left or right slot keeps its
---    own mode, as macOS reads the mode of resolveSwipeSlot's answer.
--- 5. Pure: travel in, fire requests out, through the caller's fire function.
--- ==============================================================================

local M = {}

local Direction = require("gestures.direction")
local Incremental = require("gestures.incremental")

-- Travel, in millimetres, before a moving swipe has a direction (the macOS
-- SWIPE_MIN of three fingers and more).
M.SWIPE_MIN_MM = 1.5

-- Smallest reversal the tracker accepts, in millimetres (macOS LIVE_AXIS_MIN).
M.REVERSE_FLOOR_MM = 1.0

--- Creates a tracker.
--- @param opts table { units_x, units_y (device units per mm), mode_of(slot), step_of(slot),
---   slot_of(slot, fingers, direction) -> the slot whose mode and step apply (an axis slot
---   answering for an unbound direction one), fire(slot, fingers, direction, count) -> fired count }
--- @return table tracker
function M.new(opts)
	assert(type(opts) == "table", "incremental tracker needs its options")
	assert(type(opts.units_x) == "number" and opts.units_x > 0 and type(opts.units_y) == "number" and opts.units_y > 0,
		"incremental tracker needs the touchpad resolution in units per millimetre")
	for _, name in ipairs({ "mode_of", "step_of", "slot_of", "fire" }) do
		assert(type(opts[name]) == "function", "incremental tracker needs " .. name)
	end
	local tracker = {}
	local state

	local function reset() state = nil end
	reset()

	--- Feeds the decoder's live travel of one frame.
	--- @param progress table|nil { fingers, dx, dy } in device units.
	function tracker:update(progress)
		if type(progress) ~= "table" then return end
		local x, y = progress.dx / opts.units_x, progress.dy / opts.units_y
		if not state or state.fingers ~= progress.fingers then
			-- The decoder's travel already starts where this finger count
			-- started: the frames it took to hold the count are swipe too, and
			-- a brisk swipe moves from its first frame.
			state = { fingers = progress.fingers, ox = 0, oy = 0, committed = 0, fired = state and state.fired or false }
		end
		if state.dead then return end
		local rx, ry = x - state.ox, y - state.oy
		-- Only a decided axis counts: in the diagonal sector below the diagonal
		-- minimum the classifier names the dominant straight axis, and the
		-- name turning diagonal a frame later restarted the count each time.
		local axis = Direction.decided_axis(rx, ry, M.SWIPE_MIN_MM, M.SWIPE_MIN_MM * Direction.DIAGONAL_MINIMUM_FACTOR)
		if not axis then return end
		local direction = Direction.name(axis, rx, ry)
		local slot = string.format("swipe_%d_%s", math.min(progress.fingers, 5), direction)
		local answering = opts.slot_of(slot, progress.fingers, direction)
		if opts.mode_of(answering) ~= "incremental" then return end
		local step = opts.step_of(answering)

		-- Travel along the direction's own axis, a diagonal's included (shared
		-- with the macOS engine).
		local function along(dx, dy) return Direction.along(direction, dx, dy) end

		if state.sign and state.lx then
			local back = along(x - state.lx, y - state.ly)
			local sign = back > 0 and 1 or (back < 0 and -1 or 0)
			if sign ~= 0 and sign ~= state.sign and math.abs(back) >= Incremental.reverse_min(step, M.REVERSE_FLOOR_MM) then
				state.ox, state.oy, state.committed, state.sign, state.lx, state.ly, state.slot = x, y, 0, nil, nil, nil, nil
				return
			end
		end
		if state.slot and state.slot ~= slot then
			-- The swipe turned onto another direction without coming back a
			-- reversal's worth: it starts counting from here.
			state.ox, state.oy, state.committed, state.sign, state.lx, state.ly = x, y, 0, nil, nil, nil
			state.slot = slot
			return
		end
		state.slot = slot

		local distance = along(rx, ry)
		local target = Incremental.steps(math.abs(distance), step)
		local wanted = target - state.committed
		if wanted <= 0 then return end
		if wanted > Incremental.MAX_ACTIONS_PER_FRAME then
			-- An implausible sensor jump is refused, not truncated.
			state.dead = true
			return
		end
		local fired = opts.fire(slot, progress.fingers, direction, wanted)
		if type(fired) ~= "number" or fired <= 0 then return end
		state.committed = state.committed + fired
		state.sign = distance > 0 and 1 or -1
		state.lx, state.ly = x, y
		state.fired = true
	end

	--- Ends the touch.
	--- @return boolean consumed True when the swipe already acted while moving,
	---   so its completed form must not fire once more.
	function tracker:finish()
		local consumed = state ~= nil and state.fired == true
		reset()
		return consumed
	end

	return tracker
end

return M
