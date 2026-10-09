--- tests/unit/modules/shortcuts/test_actions_system.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture

helpers.describe("shortcuts.actions.system", function()
	helpers.it("toggle_awake creates an event watcher with the correct events", function()
		with_fixture(function()
			package.loaded["infra.keycodes"] = nil
			package.loaded["modules.shortcuts.actions.system"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			local sys = load_system()
			-- load_with_stubs builds a FRESH stub table per call, so the one captured
			-- at the top of this file is not the one the module just bound. Read the
			-- live global instead — the same trap the KEYSTROKES comment in
			-- tests/stubs/hs.lua documents for keystroke assertions.
			local hs_live = _G.hs
			hs_live.eventtap.__reset()

			sys.toggle_awake()

			-- This case used to say it "cannot easily assert the exact watch_types
			-- without deep introspection of the eventtap stub" and assert true twice.
			-- The stub was the problem, not the assertion: hs.eventtap.new discarded
			-- both its arguments. It records them now, so the claim in the case name
			-- is the claim being checked.
			local taps = hs_live.eventtap.__taps
			helpers.assert_eq(#taps, 1, "keep-awake must install exactly one input watcher")

			local watched = {}
			for _, t in ipairs(taps[1].types or {}) do watched[t] = true end
			local ev = hs_live.eventtap.event.types
			-- The point of the watcher is to stop the jiggler the moment the user is
			-- back. A list missing keyDown means typing does not count as being back,
			-- and the cursor keeps moving under their hands.
			helpers.assert_true(watched[ev.keyDown], "a key press must count as user activity")
			helpers.assert_true(watched[ev.leftMouseUp] or watched[ev.leftMouseDown],
				"so must a click")
			helpers.assert_true(taps[1].started >= 1, "the watcher must actually be started")

			sys.toggle_awake()
			helpers.assert_true(taps[1].stopped >= 1,
				"toggling keep-awake off must stop the watcher — an eventtap left running "
					.. "keeps consuming every event the user generates for the rest of the session")
		end)
	end)
end)
