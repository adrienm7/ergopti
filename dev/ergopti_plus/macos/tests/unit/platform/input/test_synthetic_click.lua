--- tests/unit/platform/input/test_synthetic_click.lua

--- ==============================================================================
--- MODULE: Synthetic Click
--- DESCRIPTION:
--- Drives the workflow click owner against a recording synthetic input: a
--- double click posts two down/up pairs with click states 1 and 2, the middle
--- button carries its button number, a refused up is replaced by a cleanup
--- release, and a click is refused while a gesture holds a button down.
---
--- ROOT CAUSE ENCODED:
--- A workflow's « click at coordinates » step was refused on macOS: nothing
--- posted the click, and without the click state Quartz would read a double
--- click as two single ones.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A recording synthetic input.
--- @param refuse_up_at integer|nil The post index at which an up is refused.
--- @return table deps, table posted
local function world(refuse_up_at)
	local posted = {}
	local types = {
		leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4,
		otherMouseDown = 25, otherMouseUp = 26,
	}
	local deps = {
		held = function() return false end,
		synthetic = {
			mouse_event_type = function(name) return assert(types[name], name) end,
			prepare_mouse_event = function(owner, event_type, position, options)
				return { owner = owner, type = event_type, x = position.x, y = position.y,
					phase = options.phase, state = options.click_state, button = options.button_number }
			end,
			prepare_mouse_cleanup_event = function(owner, event_type, position, options)
				return { owner = owner, type = event_type, x = position.x, phase = options.phase,
					cleanup = true, button = options.button_number }
			end,
			post_mouse_event = function(event)
				posted[#posted + 1] = event
				if refuse_up_at == #posted then return false, "refused" end
				return true
			end,
		},
	}
	return deps, posted
end

helpers.describe("synthetic click (workflow-click)", function()
	helpers.it("a double click posts two pairs with click states 1 and 2 (workflow-click)", function()
		package.loaded["platform.input.synthetic_click"] = nil
		local Click = require("platform.input.synthetic_click")
		local deps, posted = world()
		helpers.assert_eq(Click.click(10, 20, "left", 2, deps), true)
		helpers.assert_eq(#posted, 4)
		local seen = {}
		for _, event in ipairs(posted) do seen[#seen + 1] = event.phase .. event.state end
		helpers.assert_eq(table.concat(seen, ","), "down1,up1,down2,up2")
		helpers.assert_eq(posted[1].type, 1)
		helpers.assert_eq(posted[4].type, 2)
		helpers.assert_eq(posted[1].x, 10)
		helpers.assert_eq(posted[1].owner, "workflow_click")
	end)

	helpers.it("the middle button carries its button number (workflow-click)", function()
		local Click = require("platform.input.synthetic_click")
		local deps, posted = world()
		helpers.assert_eq(Click.click(0, 0, "middle", 1, deps), true)
		helpers.assert_eq(posted[1].type, 25)
		helpers.assert_eq(posted[1].button, 2)
		helpers.assert_eq(posted[2].button, 2)
	end)

	helpers.it("a refused up is released by the cleanup event (workflow-click)", function()
		local Click = require("platform.input.synthetic_click")
		local deps, posted = world(2)
		local clicked, detail = Click.click(5, 5, "right", 1, deps)
		helpers.assert_eq(clicked, false)
		helpers.assert_eq(detail, "refused")
		helpers.assert_eq(#posted, 3)
		helpers.assert_eq(posted[3].cleanup, true, "the held button must be released")
		helpers.assert_eq(posted[3].type, 4)
	end)

	helpers.it("a click is refused while a gesture holds a button (workflow-click)", function()
		local Click = require("platform.input.synthetic_click")
		local deps, posted = world()
		deps.held = function() return true end
		local clicked, detail = Click.click(1, 1, "left", 1, deps)
		helpers.assert_eq(clicked, false)
		helpers.assert_eq(detail, "button_held")
		helpers.assert_eq(#posted, 0)
	end)
end)
