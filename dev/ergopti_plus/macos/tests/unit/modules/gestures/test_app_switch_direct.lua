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
--- Cmd+Shift+Tab (cmd_shift_tab) failed the same way, and a posted Cmd+`
--- (the active application's windows) needs a layout carrying a backquote.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

local Desk = require("tests.support.app_switch_desk")
local with_desk, window, tap = Desk.with_desk, Desk.window, Desk.tap
local FRONT, OTHER, THIRD, OWN = Desk.FRONT, Desk.OTHER, Desk.THIRD, Desk.OWN
local LEFT_SCREEN, RIGHT_SCREEN = Desk.LEFT_SCREEN, Desk.RIGHT_SCREEN

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

	-- app_switcher posted the same Cmd+Tab; macOS no longer offers it, and a
	-- stored one becomes app_previous (test_app_switch_labels.lua).

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

	--- Three windows of the active application, the middle one focused.
	local function app_windows_desk(focused)
		return {
			front = FRONT,
			focused = focused,
			cursor_screen = LEFT_SCREEN,
			windows = {
				window(52, FRONT, LEFT_SCREEN),
				window(22, OTHER, LEFT_SCREEN),
				window(51, FRONT, LEFT_SCREEN),
				window(55, FRONT, RIGHT_SCREEN, { minimized = true }),
				window(53, FRONT, LEFT_SCREEN, { standard = false }),
				window(54, FRONT, RIGHT_SCREEN),
			},
		}
	end

	it("(app-switch-direct) win_app_next and win_app_prev cycle the active app's windows with no keystroke",
		function(fresh_actions)
			with_desk(app_windows_desk(52), function(focused)
				local accepted, calls = tap(fresh_actions, "win_app_next")
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(#calls.keys, 0, "a posted Cmd+` depends on the layout carrying a backquote")
				helpers.assert_eq(focused, { 54 }, "creation order, passing over minimised and non-standard windows")
			end)
			with_desk(app_windows_desk(52), function(focused)
				tap(fresh_actions, "win_app_prev")
				helpers.assert_eq(focused, { 51 })
			end)
		end)

	it("(app-switch-direct) the window cycle wraps around and starts at an edge from a panel",
		function(fresh_actions)
			with_desk(app_windows_desk(54), function(focused)
				tap(fresh_actions, "win_app_next")
				helpers.assert_eq(focused, { 51 }, "past the last window comes the first")
			end)
			with_desk(app_windows_desk(53), function(focused)
				tap(fresh_actions, "win_app_prev")
				helpers.assert_eq(focused, { 54 }, "a focused panel is no listed window")
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
