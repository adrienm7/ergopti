--- tests/unit/modules/gestures/test_app_switch_direct.lua

--- ==============================================================================
--- MODULE: Previous application switches directly (app-switch-direct)
--- DESCRIPTION:
--- Dispatches the previous-application actions through the real registry, on a
--- desk of windows served by a recording window adapter, and fires the deferred
--- switch the action schedules.
---
--- ROOT CAUSE ENCODED:
--- app_previous and app_switcher posted a synthetic Cmd+Tab. The Dock commits
--- its switcher only when Command itself is released, which a posted Tab
--- keystroke carrying the Command flag never does: a single three-finger tap did
--- nothing and a quick double tap left the switcher open on screen. The action
--- must focus the previous application's window itself, with no keystroke, and
--- the screen-scoped twin must keep to the screen under the cursor. A posted
--- Cmd+Shift+Tab (cmd_shift_tab) failed the same way.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

-- Stable process ids of the desk. OWN is this runtime.
local FRONT, OTHER, THIRD, OWN = 101, 202, 303, 909
local LEFT_SCREEN, RIGHT_SCREEN = 1, 2

local INJECTED = {
	"adapters.window_manager",
	"adapters.mouse_control",
	"modules.gestures.app_switch",
}

--- Serves a desk of windows to the switch and records every focus request.
--- @param desk table { front, cursor_screen, windows = { record... } }, front to back.
--- @param body function body(focused) runs with the desk installed.
local function with_desk(desk, body)
	local saved = {}
	for _, name in ipairs(INJECTED) do saved[name] = package.loaded[name] end
	local focused = {}
	package.loaded["adapters.window_manager"] = {
		ordered_windows = function()
			local copy = {}
			for index, record in ipairs(desk.windows) do copy[index] = record end
			return copy
		end,
		frontmost_pid = function() return desk.front end,
		own_pid = function() return OWN end,
		focus_window = function(record)
			focused[#focused + 1] = record.id
			return record.refuses_focus ~= true
		end,
	}
	package.loaded["adapters.mouse_control"] = {
		screen_id_under_cursor = function() return desk.cursor_screen end,
	}
	package.loaded["modules.gestures.app_switch"] = nil
	local ok, err = xpcall(body, debug.traceback, focused)
	for _, name in ipairs(INJECTED) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- @return table A standard, visible window record.
local function window(id, pid, screen_id, extra)
	local record = { id = id, pid = pid, screen_id = screen_id, standard = true, minimized = false }
	for key, value in pairs(extra or {}) do record[key] = value end
	return record
end

--- Dispatches one action like a tap and fires what it scheduled.
--- @return boolean accepted, table calls
local function tap(fresh_actions, action, binding)
	local actions, calls = fresh_actions()
	local accepted = actions.execute_single(action, binding or "tap_3")
	for _, entry in ipairs(calls.after) do calls.fire(entry.token) end
	return accepted, calls
end

--- The desk of the maintainer's report: the frontmost application on the left
--- screen, the previous one on the right screen, an older one on the left.
local function two_screen_desk(cursor_screen)
	return {
		front = FRONT,
		cursor_screen = cursor_screen,
		windows = {
			window(11, FRONT, LEFT_SCREEN),
			window(22, OTHER, RIGHT_SCREEN),
			window(33, THIRD, LEFT_SCREEN),
		},
	}
end

helpers.describe("previous application switches directly (app-switch-direct)", function()
	it("(app-switch-direct) one tap on app_previous activates the previous app with no synthetic Cmd+Tab",
		function(fresh_actions)
			with_desk(two_screen_desk(LEFT_SCREEN), function(focused)
				local accepted, calls = tap(fresh_actions, "app_previous")
				helpers.assert_eq(accepted, true, "app_previous must be a dispatchable action")
				helpers.assert_eq(#calls.keys, 0,
					"no synthetic keystroke may stand in for the switch (Cmd+Tab needs a real Command release)")
				helpers.assert_eq(focused, { 22 },
					"one tap must focus the most recent other application, on any screen")
			end)
		end)

	it("(app-switch-direct) app_switcher takes the same direct path, with no synthetic Cmd+Tab",
		function(fresh_actions)
			with_desk(two_screen_desk(LEFT_SCREEN), function(focused)
				local accepted, calls = tap(fresh_actions, "app_switcher")
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#calls.keys, 0, "app_switcher posted the same dead Cmd+Tab")
				helpers.assert_eq(focused, { 22 })
			end)
		end)

	it("(app-switch-direct) app_previous_screen keeps to the screen under the cursor",
		function(fresh_actions)
			with_desk(two_screen_desk(LEFT_SCREEN), function(focused)
				local accepted, calls = tap(fresh_actions, "app_previous_screen")
				helpers.assert_eq(accepted, true, "the screen-scoped previous app must exist")
				helpers.assert_eq(#calls.keys, 0)
				helpers.assert_eq(focused, { 33 },
					"the more recent application on the other screen must be passed over")
			end)
			with_desk(two_screen_desk(RIGHT_SCREEN), function(focused)
				tap(fresh_actions, "app_previous_screen")
				helpers.assert_eq(focused, { 22 })
			end)
		end)

	it("(app-switch-direct) with the cursor on no screen the screen-scoped switch does nothing",
		function(fresh_actions)
			with_desk(two_screen_desk(nil), function(focused)
				local accepted, calls = tap(fresh_actions, "app_previous_screen")
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#calls.keys, 0)
				helpers.assert_eq(focused, {}, "another screen is not this screen")
			end)
		end)

	it("(app-switch-direct) this runtime in front returns to the application the user was in",
		function(fresh_actions)
			with_desk({
				front = OWN,
				cursor_screen = LEFT_SCREEN,
				windows = {
					window(90, OWN, LEFT_SCREEN),
					window(11, FRONT, LEFT_SCREEN),
					window(22, OTHER, LEFT_SCREEN),
				},
			}, function(focused)
				tap(fresh_actions, "app_previous")
				helpers.assert_eq(focused, { 11 }, "this runtime is never a target")
			end)
		end)

	it("(app-switch-direct) minimised, non-standard and refusing windows are passed over",
		function(fresh_actions)
			with_desk({
				front = FRONT,
				cursor_screen = LEFT_SCREEN,
				windows = {
					window(11, FRONT, LEFT_SCREEN),
					window(12, FRONT, LEFT_SCREEN),
					window(40, OTHER, LEFT_SCREEN, { minimized = true }),
					window(41, OTHER, LEFT_SCREEN, { standard = false }),
					window(42, OTHER, LEFT_SCREEN, { refuses_focus = true }),
					window(33, THIRD, LEFT_SCREEN),
				},
			}, function(focused)
				tap(fresh_actions, "app_previous")
				helpers.assert_eq(focused, { 42, 33 },
					"a refusal moves on to the next application instead of ending the switch")
			end)
		end)

	it("(app-switch-direct) cmd_shift_tab activates the least recent application, with no keystroke",
		function(fresh_actions)
			with_desk({
				front = FRONT,
				cursor_screen = LEFT_SCREEN,
				windows = {
					window(11, FRONT, LEFT_SCREEN),
					window(22, OTHER, RIGHT_SCREEN),
					window(23, OTHER, LEFT_SCREEN),
					window(33, THIRD, LEFT_SCREEN),
					window(34, THIRD, RIGHT_SCREEN),
				},
			}, function(focused)
				local accepted, calls = tap(fresh_actions, "cmd_shift_tab")
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#calls.keys, 0, "a posted Cmd+Shift+Tab switched nothing either")
				helpers.assert_eq(focused, { 33 },
					"the least recent application, through its frontmost window")
			end)
		end)

	it("(app-switch-direct) a keyboard slot runs the switch under the shortcut parent",
		function(fresh_actions)
			with_desk(two_screen_desk(LEFT_SCREEN), function(focused)
				local _, calls = tap(fresh_actions, "app_previous", "keyboard__cmd_1")
				helpers.assert_eq(calls.after[1].parent, "shortcut_bindings")
				helpers.assert_eq(focused, { 22 })
			end)
		end)
end)
