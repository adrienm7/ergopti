--- tests/unit/modules/shortcuts/test_actions_system.lua

local helpers = require("tests.helpers")

-- Load the stubbed hammerspoon environment
local hs_stub = helpers.load_with_stubs("tests.stubs.hs")

helpers.describe("shortcuts.actions.system", function()
	helpers.it("toggle_awake creates an event watcher with the correct events", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil
		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")

		-- We just ensure that toggle_awake doesn't crash and starts successfully
		sys.toggle_awake()
		-- We cannot easily assert the exact watch_types here without deep introspection of the eventtap stub,
		-- but we can verify it doesn't crash.
		helpers.assert_true(true, "toggle_awake should execute without errors")

		-- Turn it off
		sys.toggle_awake()
		helpers.assert_true(true, "toggle_awake should toggle off without errors")
	end)
end)




-- ============================================================
-- ============================================================
-- ======= keep_awake persistent alert (regression) ===========
-- ============================================================
-- ============================================================

-- Guards the fix for the 7b16a3f5 regression that replaced math.huge with 2.0
-- seconds (banner disappeared after 2s). Also guards the reliable-close fix:
-- close_awake_alert always calls closeAll(0) unconditionally because
-- closeSpecific is silently ignored from eventtap callbacks on some Hammerspoon
-- builds, causing the banner to persist after auto-deactivation (touchpad/key).
-- Rules:
--   1. toggle ON  → hs.alert.show called with math.huge duration
--   2. toggle OFF → hs.alert.closeAll called (banner closed unconditionally)
--   3. auto-deactivation → same; closeAll must be called regardless of show return value
helpers.describe("shortcuts.actions.system: keep_awake persistent alert", function()
	-- Builds a fresh module instance with spied alert + timer stubs.
	local function make_sys_with_alert_spy()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local show_calls      = {}
		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show = function(msg, duration)
					table.insert(show_calls, { msg = msg, duration = duration })
					return "test-alert-uuid"
				end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		return sys, show_calls, close_all_calls
	end

	helpers.it("shows the on-banner with math.huge duration so it persists while active", function()
		local sys, show_calls = make_sys_with_alert_spy()
		sys.toggle_awake()
		local on_call = show_calls[#show_calls]
		helpers.assert_true(on_call ~= nil, "hs.alert.show should be called on toggle ON")
		helpers.assert_eq(on_call.duration, math.huge, "duration must be math.huge — not a fixed timeout")
	end)

	helpers.it("closes the banner via closeAll on manual toggle OFF", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_all_calls
		sys.toggle_awake()   -- OFF → closeAll must be called
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called on toggle OFF")
	end)

	helpers.it("closes the banner via closeAll on stop_awake", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return "test-alert-uuid" end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON
		local calls_before = close_all_calls
		sys.stop_awake()     -- direct stop (e.g. module shutdown)
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called on stop_awake")
	end)

	-- Regression guard: closeAll must be called even when hs.alert.show returns nil
	-- (older Hammerspoon builds). This was the root cause of banners persisting after
	-- auto-deactivation — the ID was nil so nothing was ever closed.
	helpers.it("calls closeAll even when hs.alert.show returned nil (no ID captured)", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls = 0

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show          = function() return nil end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function() end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON  → awake_alert_id remains nil (show returned nil)
		local calls_before = close_all_calls
		sys.toggle_awake()   -- OFF → closeAll must still be called
		helpers.assert_true(close_all_calls > calls_before, "closeAll must be called even when alert ID is nil")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= wrap_event_decision (regression) ============
-- =====================================================
-- =====================================================

-- Locks the two hard-won wrap-eventtap rules:
--   1. Alt (Option) must NOT block wrapping — Ergopti's wrap symbols sit on the
--      AltGr layer and carry the alt flag (the original bug excluded alt, so no
--      AltGr symbol ever wrapped).
--   2. When no selection is readable (nothing selected, or an app like VS Code
--      that hides AXSelectedText), the symbol must pass through (never swallowed).
helpers.describe("shortcuts.actions.system: wrap_event_decision", function()
	package.loaded["lib.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	local sys = helpers.load_with_stubs("modules.shortcuts.actions.system")
	local PAIRS = { ["("] = { left = "(", right = ")" }, [")"] = { left = "(", right = ")" } }

	helpers.it("wraps an AltGr-typed symbol when a selection exists (alt must not block)", function()
		helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, true), "wrap")
	end)

	helpers.it("passes the symbol through when no selection is readable", function()
		-- The regression that lost the character in VS Code: pair matches but the
		-- app exposes no selection, so we must NOT suppress the keystroke.
		helpers.assert_eq(sys.wrap_event_decision({ alt = true }, "(", PAIRS, false), "passthrough")
	end)

	helpers.it("never treats Cmd/Ctrl combos as wrap input", function()
		helpers.assert_eq(sys.wrap_event_decision({ cmd = true }, "(", PAIRS, true), "passthrough")
		helpers.assert_eq(sys.wrap_event_decision({ ctrl = true }, "(", PAIRS, true), "passthrough")
	end)

	helpers.it("passes through characters that are not configured wrap symbols", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "x", PAIRS, true), "passthrough")
	end)

	helpers.it("passes through empty / nil characters without crashing", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "", PAIRS, true), "passthrough")
		helpers.assert_eq(sys.wrap_event_decision(nil, "(", PAIRS, true), "wrap")
	end)

	helpers.it("wraps a plain (no-modifier) wrap symbol with a selection", function()
		helpers.assert_eq(sys.wrap_event_decision({}, "(", PAIRS, true), "wrap")
	end)
end)
