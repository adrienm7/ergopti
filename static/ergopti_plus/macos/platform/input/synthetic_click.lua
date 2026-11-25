--- platform/input/synthetic_click.lua

--- ==============================================================================
--- MODULE: Synthetic Click
--- DESCRIPTION:
--- Clicks at screen coordinates for a workflow's « click » step: count pairs of
--- down and up events of one button, each tagged by the synthetic input owner so
--- Ergopti's own taps recognise them, with the click state Quartz needs to read
--- a double or triple click as one.
---
--- FEATURES & RATIONALE:
--- 1. One owner of the native events: prepare and post go through
---    platform.input.synthetic_input, never a second event constructor.
--- 2. A down that may have reached Quartz is always released: a refused up
---    is replaced by the owner's cleanup event, so no button stays held.
--- 3. A click toggled on by a gesture (actions_click) is never released
---    behind the user's back: the click is refused while one is held.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "synthetic_click"
local OWNER = "workflow_click"

--- Event type names and button number of each button the step names.
local BUTTONS = {
	left = { down = "leftMouseDown", up = "leftMouseUp" },
	right = { down = "rightMouseDown", up = "rightMouseUp" },
	middle = { down = "otherMouseDown", up = "otherMouseUp", number = 2 },
}

--- The real dependencies.
--- @return table { synthetic, held }
local function default_deps()
	local Click = require("gestures.engine.actions_click")
	return {
		synthetic = require("platform.input.synthetic_input"),
		held = function() return Click.is_left_click_held() or Click.is_right_click_held() end,
	}
end

--- Prepares and posts one event; a refused down is released at once.
--- @param deps table
--- @param kind string "down" or "up".
--- @param spec table A BUTTONS entry.
--- @param position table { x, y }.
--- @param state integer The click state.
--- @return boolean posted
--- @return string|nil detail
local function post(deps, kind, spec, position, state)
	local event, detail = deps.synthetic.prepare_mouse_event(OWNER, deps.synthetic.mouse_event_type(spec[kind]), position,
		{ phase = kind, click_state = state, button_number = spec.number })
	if event == nil then return false, detail end
	return deps.synthetic.post_mouse_event(event)
end

--- Releases a button whose down may have reached Quartz.
--- @param deps table
--- @param spec table A BUTTONS entry.
--- @param position table { x, y }.
local function release(deps, spec, position)
	local event, detail = deps.synthetic.prepare_mouse_cleanup_event(OWNER, deps.synthetic.mouse_event_type(spec.up), position,
		{ phase = "up", button_number = spec.number })
	local released = event ~= nil and deps.synthetic.post_mouse_event(event) == true
	if not released then
		Logger.error(LOG, "A workflow click's button may stay held: its release was refused (%s).", tostring(detail))
	end
end

--- Clicks count times with one button at (x, y).
--- @param x integer Screen x.
--- @param y integer Screen y.
--- @param button string left, right or middle.
--- @param count integer At least 1.
--- @param deps table|nil { synthetic, held } (tests).
--- @return boolean clicked
--- @return string|nil detail Why it did not.
function M.click(x, y, button, count, deps)
	local spec = BUTTONS[button]
	assert(spec ~= nil, "synthetic_click: unknown button")
	assert(math.tointeger(count) ~= nil and count >= 1, "synthetic_click: count must be a positive integer")
	deps = deps or default_deps()
	if deps.held() then
		Logger.warn(LOG, "A workflow click was refused: a gesture holds a mouse button down.")
		return false, "button_held"
	end
	local position = { x = x, y = y }
	for state = 1, count do
		local down_ok, down_detail = post(deps, "down", spec, position, state)
		if not down_ok then
			release(deps, spec, position)
			return false, down_detail
		end
		local up_ok, up_detail = post(deps, "up", spec, position, state)
		if not up_ok then
			release(deps, spec, position)
			return false, up_detail
		end
	end
	return true
end

return M
