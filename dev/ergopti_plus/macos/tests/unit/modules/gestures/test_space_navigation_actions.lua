--- tests/unit/modules/gestures/test_space_navigation_actions.lua

--- ==============================================================================
--- MODULE: Space navigation actions, plain and wrapping (macOS)
--- DESCRIPTION:
--- Runs the real gesture action registry against a scripted Spaces binding:
--- the focused screen's Spaces, the focused Space, and a recording gotoSpace
--- and Dock toggle. Keystrokes are the ones the registry hands the synthetic
--- input broker.
---
--- ROOT CAUSE ENCODED:
--- Nothing wrapped. A global "circular Spaces" checkbox decided whether
--- space_prev / space_next stopped at the edge, but macOS itself stops at the
--- first and last Space, so the setting only chose between a bounce and no
--- bounce. The wrap is now its own pair of actions: at the edge they jump to
--- the other end of the focused screen (gotoSpace, then one Ctrl+Arrow per Space
--- when that is refused), and the plain pair never wraps.
--- Mission Control and App Exposé posted the F3 key and Ctrl+Down, which do
--- nothing once the user changes or disables those shortcuts; they now ask the
--- Dock directly.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

local LEFT, RIGHT = 123, 124

--- Scripts the Spaces binding of the loaded stub.
--- @param calls table Fixture recorder.
--- @param layout table Screen UUID -> ordered Space ids.
--- @param focused integer Focused Space id.
--- @param goto_result any What gotoSpace returns.
--- @return table recorder { jumps = {ids...}, toggles = {names...} }
local function script_spaces(calls, layout, focused, goto_result)
	local recorder = { jumps = {}, toggles = {} }
	local spaces = calls.hs.spaces
	spaces.allSpaces = function() return layout end
	spaces.focusedSpace = function() return focused end
	spaces.gotoSpace = function(id)
		recorder.jumps[#recorder.jumps + 1] = id
		if goto_result == "raise" then error("Mission Control is unavailable") end
		if goto_result == true then return true end
		return nil, "the Space button was not found"
	end
	spaces.toggleMissionControl = function() recorder.toggles[#recorder.toggles + 1] = "mission_control" end
	spaces.toggleAppExpose = function() recorder.toggles[#recorder.toggles + 1] = "app_expose" end
	return recorder
end

--- Fires every deferred action the registry scheduled, in order.
--- @param calls table Fixture recorder.
local function fire_deferred(calls)
	for _, entry in ipairs(calls.after) do calls.fire(entry.token) end
end

--- @param calls table Fixture recorder.
--- @return table The recorded key codes, each with its modifier list joined.
local function keys(calls)
	local out = {}
	for _, key in ipairs(calls.keys) do
		out[#out + 1] = table.concat(key.mods or {}, "+") .. ":" .. tostring(key.key)
	end
	return out
end

helpers.describe("gestures.actions: wrapping Space navigation", function()
	it("space_next_wrap on the last Space goes to the first one", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 13, true)
		helpers.assert_true(actions.execute_single("space_next_wrap", "swipe_4_left"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 11 }, "the wrap must land on the first Space of the screen")
		helpers.assert_eq(keys(calls), {}, "a successful jump presses no key")
	end)

	it("space_prev_wrap on the first Space goes to the last one", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 11, true)
		helpers.assert_true(actions.execute_single("space_prev_wrap", "keyboard__hs_ctrl_left"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 13 })
		helpers.assert_eq(keys(calls), {})
	end)

	it("wraps within the focused screen only", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, {
			["screen-A"] = { 1, 2 },
			["screen-B"] = { 5, 6, 7, 8 },
		}, 8, true)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 5 }, "the first Space of the focused screen, not of another one")
	end)

	it("walks back one Ctrl+Arrow per Space when gotoSpace is refused", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13, 14 } }, 14, nil)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 11 })
		helpers.assert_eq(keys(calls), { "ctrl:" .. LEFT, "ctrl:" .. LEFT, "ctrl:" .. LEFT },
			"from the fourth Space back to the first is three steps left")
	end)

	it("walks when gotoSpace raises instead of refusing", function(fresh_actions)
		local actions, calls = fresh_actions()
		script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 11, "raise")
		helpers.assert_true(actions.execute_single("space_prev_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(keys(calls), { "ctrl:" .. RIGHT, "ctrl:" .. RIGHT })
	end)

	it("moves one Space with one Ctrl+Arrow away from the edge", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 12, true)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		helpers.assert_true(actions.execute_single("space_prev_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, {}, "a neighbour is one keystroke, never Mission Control")
		helpers.assert_eq(keys(calls), { "ctrl:" .. RIGHT, "ctrl:" .. LEFT })
	end)

	it("wraps between two Spaces with the one Ctrl+Arrow that points at the other", function(fresh_actions)
		-- With two Spaces the wrap from either edge is a single step, but in the
		-- direction OPPOSITE to the one asked for: pressing the requested arrow
		-- runs into the edge and macOS stays put.
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12 } }, 12, true)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(keys(calls), { "ctrl:" .. LEFT }, "from the second of two Spaces, next wraps left")
		helpers.assert_eq(spaces.jumps, {}, "a neighbour is one keystroke, never Mission Control")

		actions, calls = fresh_actions()
		spaces = script_spaces(calls, { ["screen-A"] = { 11, 12 } }, 11, true)
		helpers.assert_true(actions.execute_single("space_prev_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(keys(calls), { "ctrl:" .. RIGHT }, "from the first of two Spaces, prev wraps right")
		helpers.assert_eq(spaces.jumps, {})
	end)

	it("reads the layout once and the focused Space on every navigation", function(fresh_actions)
		local actions, calls = fresh_actions()
		script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 12, true)
		local layout_reads, focus_reads = 0, 0
		local spaces = calls.hs.spaces
		local all_spaces, focused_space = spaces.allSpaces, spaces.focusedSpace
		spaces.allSpaces = function() layout_reads = layout_reads + 1; return all_spaces() end
		spaces.focusedSpace = function() focus_reads = focus_reads + 1; return focused_space() end
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		helpers.assert_true(actions.execute_single("space_prev_wrap"))
		helpers.assert_eq(layout_reads, 1, "the layout is a private-API round-trip on the gesture callback")
		helpers.assert_eq(focus_reads, 2, "the focused Space changes with every navigation")
	end)

	it("re-reads a stale layout that does not hold the focused Space", function(fresh_actions)
		local actions, calls = fresh_actions()
		local layout = { ["screen-A"] = { 11, 12 } }
		local focused = 12
		local spaces = script_spaces(calls, layout, focused, true)
		calls.hs.spaces.allSpaces = function() return layout end
		calls.hs.spaces.focusedSpace = function() return focused end
		helpers.assert_true(actions.execute_single("space_prev_wrap"))
		-- A third desktop is added and focused within the cache lifetime.
		layout = { ["screen-A"] = { 11, 12, 13 } }
		focused = 13
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 11 }, "the new last Space must wrap to the first")
	end)

	it("defers the edge jump out of the callback that asked for it", function(fresh_actions)
		-- gotoSpace waits for Mission Control on the run loop: inside the
		-- gesture or hotkey callback it would stall the typing tap.
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 13, true)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		helpers.assert_eq(#calls.after, 1, "the jump must be scheduled, not run")
		helpers.assert_eq(calls.after[1].label, "space wrap")
		helpers.assert_eq(spaces.jumps, {}, "nothing may reach Mission Control before the timer fires")
		helpers.assert_eq(keys(calls), {})
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, { 11 })
	end)

	it("steps once without wrapping, and says so, when the layout is unreadable", function(fresh_actions)
		for _, case in ipairs({
			{ name = "allSpaces raises", break_it = function(spaces)
				spaces.allSpaces = function() error("private API gone") end
			end },
			{ name = "no focused Space", break_it = function(spaces)
				spaces.focusedSpace = function() return nil end
			end },
			{ name = "focused Space on no screen", break_it = function(spaces)
				spaces.focusedSpace = function() return 99 end
			end },
		}) do
			local actions, calls = fresh_actions()
			local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 13, true)
			case.break_it(calls.hs.spaces)
			local warnings = {}
			package.loaded["infra.logger"].warn = function(_, message) warnings[#warnings + 1] = message end
			helpers.assert_true(actions.execute_single("space_next_wrap"), case.name)
			fire_deferred(calls)
			helpers.assert_eq(keys(calls), { "ctrl:" .. RIGHT }, case.name .. ": one plain step")
			helpers.assert_eq(spaces.jumps, {}, case.name .. ": no jump without a layout")
			helpers.assert_eq(#warnings, 1, case.name .. ": the missed wrap must be logged")
		end
	end)

	it("does nothing with a single Space", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11 } }, 11, true)
		helpers.assert_true(actions.execute_single("space_next_wrap"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, {})
		helpers.assert_eq(keys(calls), {})
	end)
end)

helpers.describe("gestures.actions: plain Space navigation never wraps", function()
	it("space_next on the last Space presses Ctrl+Right and never jumps", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11, 12, 13 } }, 13, true)
		helpers.assert_true(actions.execute_single("space_next"))
		helpers.assert_true(actions.execute_single("space_prev"))
		fire_deferred(calls)
		helpers.assert_eq(spaces.jumps, {}, "the plain actions leave the edge to macOS, which stops there")
		helpers.assert_eq(keys(calls), { "ctrl:" .. RIGHT, "ctrl:" .. LEFT })
	end)
end)

helpers.describe("gestures.actions: Mission Control and App Exposé ask the Dock", function()
	it("toggles Mission Control and App Exposé without a keystroke", function(fresh_actions)
		local actions, calls = fresh_actions()
		local spaces = script_spaces(calls, { ["screen-A"] = { 11 } }, 11, true)
		helpers.assert_true(actions.execute_single("mission_control"))
		helpers.assert_true(actions.execute_single("app_expose", "keyboard__cmd_e"))
		helpers.assert_eq(spaces.toggles, { "mission_control", "app_expose" })
		helpers.assert_eq(keys(calls), {}, "a shortcut the user remapped must not decide whether this works")
	end)
end)
