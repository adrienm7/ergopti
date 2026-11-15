--- infra/absolute_motion.lua

--- ==============================================================================
--- MODULE: Absolute Pointer Motion Tracker (Linux)
--- DESCRIPTION:
--- Tells a meaningful movement of an absolute pointer (a touchpad, a tablet)
--- from the coordinates it merely reports. A relative mouse sends a delta, so
--- every EV_REL report is a movement; an absolute device sends the position,
--- which is a movement only when it differs from the previous one.
---
--- FEATURES & RATIONALE:
--- 1. Initial Reports Are Ignored: the first coordinate of a contact only
---    establishes the previous position; the contact itself is the "touch"
---    kind, not a movement.
--- 2. A Lifted Finger Forgets: the next landing starts afresh instead of
---    jumping from where the last contact ended.
--- 3. Per Source: each reader slot keeps its own coordinates.
--- ==============================================================================

local M = {}

local InputEvent = require("platform.input.event")

--- Builds an independent tracker.
--- @return table tracker `observe(slot, code, value)`, `lift(slot)`, `reset()`.
function M.new()
	local previous = {}
	local tracker = {}

	--- Records one EV_ABS coordinate.
	--- @param slot string The pointer's reader slot.
	--- @param code integer ABS_X or ABS_Y; any other axis is no pointer motion.
	--- @param value integer Absolute coordinate.
	--- @return boolean moved True when the coordinate differs from the known one.
	function tracker.observe(slot, code, value)
		if code ~= InputEvent.ABS_X and code ~= InputEvent.ABS_Y then return false end
		if type(value) ~= "number" then error("absolute_motion: a numeric coordinate is required", 2) end
		local axes = previous[slot]
		if not axes then
			axes = {}
			previous[slot] = axes
		end
		local before = axes[code]
		axes[code] = value
		return before ~= nil and before ~= value
	end

	--- Forgets the coordinates of one source (its contact ended).
	--- @param slot string The pointer's reader slot.
	function tracker.lift(slot)
		previous[slot] = nil
	end

	--- Forgets every source (the hook stopped).
	function tracker.reset()
		previous = {}
	end

	return tracker
end

return M
