--- tests/unit/modules/keymap/eventtap/test_selftest_scratch_window_typing.lua

--- ==============================================================================
--- MODULE: The Field Run's Scratch Window Is a Typing Destination (regression)
--- DESCRIPTION:
--- keymap.utils classifies every Hammerspoon window as ignored, so the keymap
--- passes keys through there untouched. The field run's scratch window is a
--- Hammerspoon window, and its hotstring check typed a trigger that never
--- expanded (field run 2026-10-31, hotstring_expanded=not_expanded). Only the
--- published scratch window is a destination, and only while it is published.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

local SCRATCH_ID, CONSOLE_ID = 3466, 12

--- Focuses one Hammerspoon window.
--- @param state table { window_id }.
local function install_hammerspoon_focus(state)
	local function watcher()
		return { start = function(self) return self end, stop = function(self) return self end }
	end
	hs.application.watcher.new = watcher
	local app = { pid = function() return 77295 end, name = function() return "Hammerspoon" end,
		newWatcher = watcher }
	hs.window.focusedWindow = function()
		return {
			id = function() return state.window_id end,
			application = function() return app end,
			title = function() return "Ergopti field run" end,
			newWatcher = watcher,
		}
	end
end

--- Runs every zero-delay timer, as the runloop would.
local function drain_immediate_timers()
	for _ = 1, 32 do
		local pending = {}
		for _, timer in ipairs(hs.timer.__timers or {}) do
			if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
		end
		if #pending == 0 then return end
		for _, timer in ipairs(pending) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end

helpers.describe("keymap.utils: the field run's scratch window (selftest-scratch-window-typing)", function()
	helpers.it("types hotstrings in the published scratch window only, while it is published", function()
		package.loaded["infra.field_run_selftest"] = nil
		package.loaded["modules.keymap.utils"] = nil
		local Selftest = require("infra.field_run_selftest")
		local KU = helpers.load_with_stubs("modules.keymap.utils")
		local state = { window_id = SCRATCH_ID }
		install_hammerspoon_focus(state)
		KU.start_ignored_win_tracking({}, {})
		KU.prewarm_ignored_win_watchers({}, {})
		helpers.assert_eq(KU.is_ignored_window({}, {}), true, "an unpublished Hammerspoon window is ignored")

		local generation = Selftest.publish(SCRATCH_ID)
		helpers.assert_nil(KU.is_ignored_window({}, {}), "a publication invalidates the cached answer")
		drain_immediate_timers()
		helpers.assert_eq(KU.is_ignored_window({}, {}), false, "the published scratch window takes typing")

		state.window_id = CONSOLE_ID
		KU.prewarm_ignored_win_watchers({}, {})
		helpers.assert_eq(KU.is_ignored_window({}, {}), true, "every other Hammerspoon window stays ignored")

		state.window_id = SCRATCH_ID
		KU.prewarm_ignored_win_watchers({}, {})
		helpers.assert_eq(KU.is_ignored_window({}, {}), false)
		Selftest.retract(generation)
		helpers.assert_nil(KU.is_ignored_window({}, {}), "a retraction invalidates the cached answer")
		drain_immediate_timers()
		helpers.assert_eq(KU.is_ignored_window({}, {}), true, "a retracted scratch window is ignored again")
		KU.stop()
	end)
end)
