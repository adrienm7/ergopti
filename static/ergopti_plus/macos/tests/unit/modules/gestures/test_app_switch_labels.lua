--- tests/unit/modules/gestures/test_app_switch_labels.lua

--- ==============================================================================
--- MODULE: One macOS action per switch (app-switch-labels)
--- DESCRIPTION:
--- Runs every app and window switching action the macOS picker offers on the
--- same desks and compares what each one did: the windows it focused and the
--- keystrokes it posted. Two actions that do the same thing everywhere are one
--- action under two names.
---
--- ROOT CAUSE ENCODED:
--- The picker offered app_switcher and app_previous (both a posted Cmd+Tab),
--- alt_tab_apps (the same previous application through Alt+F17), and
--- app_window_previous, win_next and cycle_windows_in_app (all the next window
--- of the active application), under labels that did not say which was which.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local Desk = require("tests.support.app_switch_desk")
local it = Fixture.it

local window = Desk.window
local FRONT, OTHER, THIRD = Desk.FRONT, Desk.OTHER, Desk.THIRD
local LEFT_SCREEN, RIGHT_SCREEN = Desk.LEFT_SCREEN, Desk.RIGHT_SCREEN

-- Direct activation family. The native switcher has independent input/source
-- tests in test_native_app_switcher_action and test_system_switcher_input.
local SWITCHING = {
	"app_previous", "app_previous_screen", "alt_tab_apps",
	"cmd_shift_tab", "app_window_previous", "alt_tab_windows", "alt_tab_monitor",
	"win_prev", "win_next", "win_app_prev", "win_app_next", "cycle_windows_in_app",
}

-- The ids the v5_to_v6 migration maps away on macOS.
local MERGED = {
	alt_tab_apps = "app_previous",
	app_window_previous = "win_app_next", cycle_windows_in_app = "win_app_next",
	win_prev = "win_app_prev", win_next = "win_app_next",
}

--- Desks every action runs on: three windows of the active application, the
--- middle one focused, another application on each screen, the cursor on one.
--- @return table desks
local function desks()
	local result = {}
	for _, cursor in ipairs({ LEFT_SCREEN, RIGHT_SCREEN }) do
		result[#result + 1] = {
			front = FRONT,
			focused = 12,
			cursor_screen = cursor,
			windows = {
				window(12, FRONT, LEFT_SCREEN),
				window(22, OTHER, RIGHT_SCREEN),
				window(11, FRONT, LEFT_SCREEN),
				window(33, THIRD, LEFT_SCREEN),
				window(13, FRONT, RIGHT_SCREEN),
			},
		}
	end
	return result
end

--- @return table ids The switching ids the macOS catalogue offers.
local function offered()
	local catalogue = require("_generated.action_catalogue")
	local ids = {}
	for _, id in ipairs(SWITCHING) do
		if catalogue.actions[id] ~= nil then ids[#ids + 1] = id end
	end
	return ids
end

--- Describes what one action did on every desk.
--- @return string signature
local function signature(fresh_actions, id)
	local parts = {}
	for index, desk in ipairs(desks()) do
		Desk.with_desk(desk, function(focused)
			local accepted, calls = Desk.tap(fresh_actions, id)
			local keys = {}
			for _, key in ipairs(calls.keys) do
				keys[#keys + 1] = table.concat(key.mods or {}, "+") .. "+" .. tostring(key.key)
			end
			local ids = {}
			for _, window_id in ipairs(focused) do ids[#ids + 1] = tostring(window_id) end
			parts[#parts + 1] = string.format("desk%d:%s:keys[%s]:focus[%s]", index,
				tostring(accepted), table.concat(keys, ","), table.concat(ids, ","))
		end)
	end
	return table.concat(parts, " ")
end

helpers.describe("one macOS action per switch (app-switch-labels)", function()
	it("(app-switch-labels) no two switching actions of the macOS picker do the same thing",
		function(fresh_actions)
			local ids = offered()
			helpers.assert_true(#ids >= 7, "the switching family must be read from the catalogue")
			local seen = {}
			for _, id in ipairs(ids) do
				local done = signature(fresh_actions, id)
				helpers.assert_true(done:find("keys%[[^%]]") ~= nil or done:find("focus%[%d") ~= nil,
					id .. " must do something on the desk: " .. done)
				helpers.assert_eq(seen[done], nil,
					id .. " does what " .. tostring(seen[done]) .. " does: " .. done)
				seen[done] = id
			end
		end)

	it("(app-switch-labels) each merged id is gone from the picker and its twin is there",
		function()
			local catalogue = require("_generated.action_catalogue")
			for from, to in pairs(MERGED) do
				helpers.assert_eq(catalogue.actions[from], nil, from .. " must not be offered on macOS")
				helpers.assert_true(catalogue.actions[to] ~= nil, to .. " must be offered on macOS")
			end
			local aliases = catalogue.karabiner_aliases or {}
			helpers.assert_eq(aliases.alt_tab_apps, "app_previous",
				"the remapped Alt+F17 key keeps a label: the one of what it does")
			helpers.assert_eq(aliases.cycle_windows_in_app, "win_app_next")
		end)
end)
