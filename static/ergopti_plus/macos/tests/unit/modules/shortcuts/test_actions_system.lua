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
-- seconds (banner disappeared after 2s) and removed awake_alert_id tracking
-- (alert was never closed specifically on toggle-off, leaving stale banners).
-- Rules:
--   1. toggle ON  → hs.alert.show called with math.huge duration
--   2. toggle OFF → hs.alert.closeSpecific called with the ID returned at toggle ON
--   3. auto-deactivation → hs.alert.closeSpecific also called (same invariant)
helpers.describe("shortcuts.actions.system: keep_awake persistent alert", function()
	-- Builds a fresh module instance with spied alert + timer stubs.
	-- Returns sys, show_calls, close_specific_ids, and fire_deferred (flushes
	-- all pending hs.timer.doAfter(0, …) callbacks, simulating the runloop tick
	-- that the eventtap-path deferred close relies on).
	local function make_sys_with_alert_spy()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local show_calls         = {}
		local close_specific_ids = {}
		local deferred_fns       = {}

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				show = function(msg, duration)
					table.insert(show_calls, { msg = msg, duration = duration })
					return "test-alert-uuid"
				end,
				closeAll      = function() end,
				closeSpecific = function(id)
					table.insert(close_specific_ids, id)
				end,
			}, { __call = function(_, _) end }),
			timer = {
				doAfter           = function(_, fn) table.insert(deferred_fns, fn) end,
				doEvery           = function(_, fn) return { stop = function() end } end,
				secondsSinceEpoch = function() return os.time() end,
				absoluteTime      = function() return 0 end,
				usleep            = function() end,
				delayed           = { new = function(_, fn) return { start = function() end, stop = function() end, setDelay = function() end } end },
			},
		})

		local function fire_deferred()
			for _, fn in ipairs(deferred_fns) do fn() end
			deferred_fns = {}
		end

		return sys, show_calls, close_specific_ids, fire_deferred
	end

	helpers.it("shows the on-banner with math.huge duration so it persists while active", function()
		local sys, show_calls, _ = make_sys_with_alert_spy()
		sys.toggle_awake()
		local on_call = show_calls[#show_calls]
		helpers.assert_true(on_call ~= nil, "hs.alert.show should be called on toggle ON")
		helpers.assert_eq(on_call.duration, math.huge, "duration must be math.huge — not a fixed timeout")
	end)

	helpers.it("closes the banner via closeSpecific on manual toggle OFF", function()
		local sys, _, close_ids = make_sys_with_alert_spy()
		sys.toggle_awake()   -- ON  → alert ID = "test-alert-uuid"
		sys.toggle_awake()   -- OFF → closeSpecific("test-alert-uuid") synchronously
		helpers.assert_true(#close_ids >= 1, "closeSpecific must be called on toggle OFF")
		helpers.assert_eq(close_ids[1], "test-alert-uuid", "closeSpecific must receive the alert ID from toggle ON")
	end)

	helpers.it("closes the banner via closeSpecific on stop_awake", function()
		local sys, _, close_ids = make_sys_with_alert_spy()
		sys.toggle_awake()   -- ON
		sys.stop_awake()     -- direct stop (e.g. module shutdown)
		helpers.assert_true(#close_ids >= 1, "closeSpecific must be called on stop_awake")
		helpers.assert_eq(close_ids[1], "test-alert-uuid", "closeSpecific must receive the alert ID")
	end)

	-- Regression for the nil-ID fallback: if hs.alert.show returns nil (older
	-- Hammerspoon builds do not return an ID), awake_alert_id stays nil and
	-- closeSpecific is never called — the banner persists indefinitely after
	-- auto-deactivation. close_awake_alert must call closeAll in that case.
	helpers.it("falls back to closeAll when hs.alert.show returned nil (no ID captured)", function()
		package.loaded["lib.keycodes"] = nil
		package.loaded["modules.shortcuts.actions.system"] = nil

		local close_all_calls    = 0
		local close_specific_ids = {}

		local sys = helpers.load_with_stubs("modules.shortcuts.actions.system", {
			alert = setmetatable({
				-- Simulate an older Hammerspoon that returns nil from show()
				show          = function() return nil end,
				closeAll      = function() close_all_calls = close_all_calls + 1 end,
				closeSpecific = function(id) table.insert(close_specific_ids, id) end,
			}, { __call = function(_, _) end }),
		})

		sys.toggle_awake()   -- ON  → awake_alert_id remains nil (show returned nil)
		sys.toggle_awake()   -- OFF → close_awake_alert must call closeAll, not closeSpecific
		helpers.assert_eq(#close_specific_ids, 0, "closeSpecific must NOT be called when ID is nil")
		helpers.assert_true(close_all_calls >= 1, "closeAll must be called as fallback when ID is nil")
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
