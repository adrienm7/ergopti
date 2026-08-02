--- tests/meta/test_menu_quit_karabiner_ownership.lua

--- ==============================================================================
--- MODULE: Regression — menubar Quit tears down Karabiner via the ownership-gated path (F-MED-13)
--- DESCRIPTION:
--- The menubar Quit action tore down Karabiner-Elements via
--- platform.remap.ke_lifecycle.run_total_reset_async() directly — a path with
--- NO is_hs_owned_bridge() check. The other two quit paths (script_quit in
--- modules/gestures/actions.lua, and hs.shutdownCallback in init.lua) both call
--- platform.remap.kill(), which gates on is_hs_owned_bridge() and leaves a
--- user-managed KE install untouched. The menubar path could therefore kill a
--- KE install Hammerspoon never started.
---
--- Fix: route the menubar Quit action through the same karabiner.kill() the
--- other two paths already use, instead of run_total_reset_async().
---
--- Same pinned-at-source pattern as the sibling M-11 test
--- (test_menu_quit_mlx_teardown.lua) — ui/menu/init.lua's Quit action lives
--- inside the heavy M.start(...) setup function, so it is not independently
--- callable without a full dependency graph; the source-level assertion still
--- fails before the fix (run_total_reset_async present, kill() absent) and
--- passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu/init.lua: Quit action tears down Karabiner via the ownership-gated kill() (F-MED-13)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/menu/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function safe_require")
		helpers.assert_true(src ~= nil, "ui/menu/init.lua source must be locatable")
		return src
	end

	local function quit_action_body(src)
		local quit_pos    = src:find("quit%s*=%s*function%(%)")
		helpers.assert_true(quit_pos ~= nil, "quit action must exist in ui/menu/init.lua")
		local os_exit_pos = src:find("os%.exit%(0%)", quit_pos)
		helpers.assert_true(os_exit_pos ~= nil, "os.exit(0) must exist after the quit action")
		return src:sub(quit_pos, os_exit_pos), quit_pos, os_exit_pos
	end

	helpers.it("Quit action body calls karabiner.kill(), matching script_quit and hs.shutdownCallback", function()
		local src = read_src()
		local body = quit_action_body(src)
		helpers.assert_true(body:find("karabiner%.kill%(%)", 1, false) ~= nil,
			"Quit action must call karabiner.kill() — the same ownership-respecting path used by " ..
			"script_quit and hs.shutdownCallback (F-MED-13)")
	end)

	helpers.it("Quit action body no longer calls the un-gated run_total_reset_async", function()
		local src = read_src()
		local body = quit_action_body(src)
		-- Match an actual CALL (".run_total_reset_async(" ), not merely the name —
		-- the fix's own explanatory comment mentions the removed function by name
		-- for documentation, which must not itself trip this assertion.
		helpers.assert_true(body:find("%.run_total_reset_async%s*%(") == nil,
			"Quit action must not call ke_lifecycle.run_total_reset_async() directly — it has no " ..
			"is_hs_owned_bridge() guard and can tear down a user-managed KE install (F-MED-13)")
	end)
end)
