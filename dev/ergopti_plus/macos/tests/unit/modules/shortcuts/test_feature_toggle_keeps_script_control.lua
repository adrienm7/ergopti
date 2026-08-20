--- tests/unit/modules/shortcuts/test_feature_toggle_keeps_script_control.lua

--- ==============================================================================
--- MODULE: Regression — "Shortcuts" feature toggle must NOT kill the script-control tap
--- DESCRIPTION:
--- Audit finding F-H5. The tray "Shortcuts" feature toggle paired
--- shortcuts.start()/shortcuts.stop() for the user-facing feature. But
--- shortcuts.stop() ALSO calls ScriptControl.stop(), which tears down the
--- AltGr+Enter/Backspace/Escape (pause/reload/quit) eventtap, and shortcuts.start()
--- is a Bindings-only proxy that never revives it — so toggling the feature off
--- then on silently and permanently killed the panic shortcuts until a reload.
---
--- Root cause encoded two ways so a regression cannot slip through:
---   1. Behavioral contract — pause_bindings()/resume_bindings() (the pair the
---      toggle now uses) stop/start ONLY bindings + keyboard shortcuts and must
---      never touch script_control, whereas stop() must.
---   2. Source invariant — the menu_shortcuts top-level feature toggle calls
---      resume_bindings/pause_bindings and contains no bare shortcuts.start/stop.
--- ==============================================================================

local helpers = require("tests.helpers")


-- 1) Behavioral contract — the toggle's pair spares the script-control tap.
helpers.describe("shortcuts feature toggle keeps the script-control tap alive", function()
	local function load_with_counting_submodules()
		local calls = { bindings_start = 0, bindings_stop = 0, kbd_start = 0, kbd_stop = 0, sc_start = 0, sc_stop = 0 }
		package.loaded["modules.shortcuts.bindings"] = {
			DEFAULT_CHATGPT_URL = "",
			start      = function() calls.bindings_start = calls.bindings_start + 1; return true end,
			stop       = function() calls.bindings_stop  = calls.bindings_stop  + 1; return true end,
			is_started = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = {
			ACTIONS = {}, ACTION_LABELS = {},
			start = function() calls.sc_start = calls.sc_start + 1; return true end,
			stop  = function() calls.sc_stop  = calls.sc_stop  + 1; return true end,
			is_paused = function() return false end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
			start = function() calls.kbd_start = calls.kbd_start + 1; return true end,
			stop  = function() calls.kbd_stop  = calls.kbd_stop  + 1; return true end,
		}
		local Shortcuts = helpers.load_with_stubs("modules.shortcuts")
		return Shortcuts, calls
	end

	local function cleanup()
		package.loaded["modules.shortcuts.bindings"]           = nil
		package.loaded["modules.shortcuts.script_control"]     = nil
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		package.loaded["modules.shortcuts"]                    = nil
	end

	helpers.it("pause_bindings() stops bindings + keyboard but NEVER the script-control tap", function()
		local Shortcuts, calls = load_with_counting_submodules()
		Shortcuts.pause_bindings()
		helpers.assert_eq(calls.bindings_stop, 1)
		helpers.assert_eq(calls.kbd_stop, 1)
		-- The whole point: the feature toggle (which now routes through this) must
		-- not take down the panic shortcuts.
		helpers.assert_eq(calls.sc_stop, 0)
		cleanup()
	end)

	helpers.it("resume_bindings() restarts bindings + keyboard but NEVER the script-control tap", function()
		local Shortcuts, calls = load_with_counting_submodules()
		Shortcuts.resume_bindings()
		helpers.assert_eq(calls.bindings_start, 1)
		helpers.assert_eq(calls.kbd_start, 1)
		helpers.assert_eq(calls.sc_start, 0)
		cleanup()
	end)

	helpers.it("stop() — distinct from the toggle path — DOES tear down script-control", function()
		local Shortcuts, calls = load_with_counting_submodules()
		Shortcuts.stop()
		-- Confirms the asymmetry the bug exploited: stop() is the tap-killer, so the
		-- feature toggle must use pause_bindings instead.
		helpers.assert_eq(calls.sc_stop, 1)
		cleanup()
	end)
end)


-- 2) Source invariant — the toggle never calls the tap-killing stop()/start.
helpers.describe("menu_shortcuts feature toggle is wired to the binding-only pair", function()
	helpers.it("the top-level toggle uses resume_bindings/pause_bindings, not shortcuts.start/stop", function()
		-- Selected by a declaration unique to ui/menu/menu_shortcuts.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_wrap_symbols_submenu")
		helpers.assert_true(src ~= nil, "ui/menu/menu_shortcuts.lua source must be locatable")

		-- Isolate the top-level feature toggle by its transaction's desired-state
		-- derivation.  The runtime must commit before `state.shortcuts` is published,
		-- so the former direct assignment is intentionally absent.
		local toggle_start = src:find("local%s+desired%s*=%s*not%s+previous", 1)
		helpers.assert_true(toggle_start ~= nil, "could not locate the Shortcuts feature toggle fn")
		local toggle = src:sub(toggle_start, toggle_start + 600)

		helpers.assert_true(toggle:find("resume_bindings", 1, true) ~= nil,
			"feature toggle must call shortcuts.resume_bindings on enable")
		helpers.assert_true(toggle:find("pause_bindings", 1, true) ~= nil,
			"feature toggle must call shortcuts.pause_bindings on disable")
		-- A regression back to the tap-killing pair must fail here.
		helpers.assert_true(toggle:find("shortcuts%.stop%s*%)") == nil,
			"feature toggle must NOT call shortcuts.stop() — it kills the script-control tap")
		helpers.assert_true(toggle:find("shortcuts%.start%s*%)") == nil,
			"feature toggle must NOT call shortcuts.start() — it never revives the tap")
	end)
end)
