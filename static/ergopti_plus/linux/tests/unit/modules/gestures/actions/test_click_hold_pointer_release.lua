--- tests/unit/modules/gestures/actions/test_click_hold_pointer_release.lua

--- ==============================================================================
--- MODULE: A Physical Click Ends a Gesture's Click Hold (Linux)
--- DESCRIPTION:
--- Windows releases a gesture's held button at the next physical mouse button
--- press (click.ahk mouse_ldown and mouse_rdown subscribers), and macOS at the
--- next mouse tap. Linux released it only at a key press: a physical click kept
--- the synthetic button down (GSX-001). A finger landing on the touchpad is no
--- button press: it is how the held button drags, so it must not release it.
--- Main's own on_click is compiled against recorded collaborators.
--- ==============================================================================

local helpers = require("tests.helpers")
local InputEvent = require("platform.input.event")

--- Compiles Main's on_click with a recording gestures manager.
--- @param released table Counter { count }.
--- @return function on_click
local function compile(released)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local first = assert(source:find("\tlocal function on_click(", 1, true))
	local last = assert(source:find("\n\tend\n", first, true))
	local body = source:sub(first, last + #"\n\tend") .. "\nreturn on_click"
	local noop = function() end
	local environment = setmetatable({
		gestures = { release_clicks_on_activity = function() released.count = released.count + 1; return true end },
		InputEvent = InputEvent,
		keystats = { discard_roi = noop },
		TapHold = { observe_copy_activity = noop },
		wrap_on_type = { on_pointer_down = noop },
		secure_focus_guard = { invalidate = noop },
		prediction_engine = nil,
		WordReset = { click_resets_word = function() return false end },
		engine = { reset = noop },
		Logger = { debug = noop },
		LOG = "test",
	}, { __index = _G })
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "Main on_click", "t", environment)) end
	return chunk()
end

helpers.describe("gesture click hold: a physical click releases it (Linux)", function()
	helpers.it("a button press releases the held button, a touch does not (gsx-001-click-releases-hold)", function()
		local released = { count = 0 }
		local on_click = compile(released)
		on_click(InputEvent.POINTER_BUTTON_FIRST)
		helpers.assert_eq(released.count, 1, "a physical button press ends the hold, as on Windows")
		on_click(InputEvent.POINTER_BUTTON_LAST)
		helpers.assert_eq(released.count, 2, "every pointer button does")
		on_click(0x14a) -- BTN_TOUCH: a finger landing on the touchpad
		helpers.assert_eq(released.count, 2, "a touch drags the held button, it does not release it")
	end)
end)
