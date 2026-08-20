--- tests/unit/ui/menu/test_menu_state_keeps_script_control.lua

--- ==============================================================================
--- MODULE: Regression — sync_state_to_modules must not destroy the script-control tap (H-1)
--- DESCRIPTION:
--- When the user clicks "Tout désactiver" the menu calls sync_state_to_modules
--- with state.shortcuts=false. The old code dispatched shortcuts_mod.stop(), which
--- destroys the script-control eventtap (AltGr+Enter/Backspace/Escape) with no
--- in-band recovery — panic shortcuts became dead until a full hs.reload.
---
--- Fix: use pause_bindings()/resume_bindings() (binding-only helpers) so the tap
--- is never touched. Pinned by two tests:
---   1. Source check: no stop()/start() call on shortcuts_mod inside sync_state_to_modules.
---   2. Behaviour check: driving sync_state_to_modules with a spy confirms only
---      pause_bindings is called when shortcuts=false, and stop is never called.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_menu_state_src()
	-- Selected by a declaration unique to ui/menu/menu_state.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("function M.sync_state_to_modules")
	helpers.assert_true(src ~= nil, "ui/menu/menu_state.lua source must be locatable")
	return src
end





-- ==========================================================================
-- ==========================================================================
-- ======= 1/ Source invariant: binding-only helpers in sync function =======
-- ==========================================================================
-- ==========================================================================

helpers.describe("menu_state: sync_state_to_modules uses pause/resume_bindings (H-1)", function()

	helpers.it("does NOT call shortcuts_mod.stop() in sync_state_to_modules", function()
		local src = read_menu_state_src()
		-- Isolate the sync function body (from its declaration to end of file).
		local sync_body = src:match("function M%.sync_state_to_modules(.+)$") or src
		helpers.assert_true(
			-- Pattern mode: %.stop matches literal ".stop" (no %-escape needed since we want pattern)
			sync_body:find("shortcuts_mod%.stop") == nil,
			"sync_state_to_modules must NOT call shortcuts_mod.stop() — it destroys the script-control tap"
		)
	end)

	helpers.it("does NOT call shortcuts_mod.start() in sync_state_to_modules", function()
		local src = read_menu_state_src()
		local sync_body = src:match("function M%.sync_state_to_modules(.+)$") or src
		helpers.assert_true(
			sync_body:find("shortcuts_mod%.start[^_]") == nil,
			"sync_state_to_modules must NOT call shortcuts_mod.start() — it destroys the script-control tap"
		)
	end)

	helpers.it("calls shortcuts_mod.pause_bindings in sync_state_to_modules", function()
		local src = read_menu_state_src()
		local sync_body = src:match("function M%.sync_state_to_modules(.+)$") or src
		helpers.assert_true(
			sync_body:find("shortcuts_mod%.pause_bindings") ~= nil,
			"sync_state_to_modules must call shortcuts_mod.pause_bindings() when shortcuts disabled"
		)
	end)

	helpers.it("calls shortcuts_mod.resume_bindings in sync_state_to_modules", function()
		local src = read_menu_state_src()
		local sync_body = src:match("function M%.sync_state_to_modules(.+)$") or src
		helpers.assert_true(
			sync_body:find("shortcuts_mod%.resume_bindings") ~= nil,
			"sync_state_to_modules must call shortcuts_mod.resume_bindings() when shortcuts enabled"
		)
	end)
end)





-- =======================================================================
-- =======================================================================
-- ======= 2/ Behaviour: spy confirms only pause_bindings is fired =======
-- =======================================================================
-- =======================================================================

helpers.describe("menu_state: spy — disable shortcuts calls pause_bindings not stop (H-1)", function()

	helpers.it("calls pause_bindings when state.shortcuts=false", function()
		local menu_state = helpers.load_with_stubs("ui.menu.menu_state")

		local called_pause   = false
		local called_resume  = false
		local called_stop    = false
		local called_start   = false

		local spy_shortcuts = {
			pause_bindings  = function() called_pause  = true; return true end,
			resume_bindings = function() called_resume = true; return true end,
			stop            = function() called_stop   = true end,
			start           = function() called_start  = true end,
		}

		local state = {
			shortcuts         = false,
			gestures          = false,
			personal_info     = false,
			hotstrings        = {},
			gesture_modes     = {},
			gesture_actions   = {},
		}
		local saved       = {}
		local config_absent = false
		local stub_editor = { set_trigger_char = function() end, set_default_section = function() end, set_close_on_add = function() end }
		local deps        = { core_mods = { shortcuts_mod = spy_shortcuts }, hotstring_editor = stub_editor }

		menu_state.sync_state_to_modules(state, saved, config_absent, deps)

		helpers.assert_true(called_pause,
			"pause_bindings must be called when state.shortcuts=false")
		helpers.assert_true(not called_stop,
			"stop() must NOT be called — it destroys the script-control tap")
		helpers.assert_true(not called_start,
			"start() must NOT be called")
		helpers.assert_true(not called_resume,
			"resume_bindings must NOT be called when shortcuts are being disabled")
	end)

	helpers.it("calls resume_bindings when state.shortcuts=true", function()
		local menu_state = helpers.load_with_stubs("ui.menu.menu_state")

		local called_pause   = false
		local called_resume  = false
		local called_stop    = false

		local spy_shortcuts = {
			pause_bindings  = function() called_pause  = true; return true end,
			resume_bindings = function() called_resume = true; return true end,
			stop            = function() called_stop   = true end,
			start           = function() end,
		}

		local state = {
			shortcuts         = true,
			gestures          = false,
			personal_info     = false,
			hotstrings        = {},
			gesture_modes     = {},
			gesture_actions   = {},
		}
		local stub_editor2 = { set_trigger_char = function() end, set_default_section = function() end, set_close_on_add = function() end }
		local deps = { core_mods = { shortcuts_mod = spy_shortcuts }, hotstring_editor = stub_editor2 }

		menu_state.sync_state_to_modules(state, {}, false, deps)

		helpers.assert_true(called_resume,
			"resume_bindings must be called when state.shortcuts=true")
		helpers.assert_true(not called_stop,
			"stop() must NOT be called even when enabling shortcuts")
		helpers.assert_true(not called_pause,
			"pause_bindings must NOT be called when enabling shortcuts")
	end)
end)
