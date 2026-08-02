--- tests/unit/modules/gestures/test_script_quit_kills_karabiner.lua

--- ==============================================================================
--- MODULE: script_quit Kills Karabiner Before Exit (regression)
--- DESCRIPTION:
--- Locks down that the `script_quit` action (bound to rcmd+Escape) tears down
--- Karabiner-Elements BEFORE quitting Hammerspoon.
---
--- ROOT CAUSE ENCODED: `script_quit` quits HS via os.exit(0), which terminates
--- the Lua VM abruptly and BYPASSES hs.shutdownCallback — where the normal KE
--- kill lives. So on the quit-shortcut path KE kept running with the Ergopti
--- rules and the physical keyboard stayed remapped after HS was gone. The action
--- must call karabiner.kill() itself. If a future edit drops that call, the spy
--- assertion below fails.
---
--- SAFETY: os.exit and hs.timer.doAfter are overridden so the action cannot
--- actually terminate the test runner; the stub timer never auto-fires anyway.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local Actions = helpers.load_with_stubs("modules.gestures.actions")

helpers.describe("gestures.actions: script_quit tears down Karabiner before exit", function()
	helpers.it("calls karabiner.kill() when the quit action runs", function()
		-- Spy Karabiner module, injected via the action's lazy require.
		local killed = { count = 0 }
		package.loaded["platform.remap"] = {
			kill = function() killed.count = killed.count + 1 end,
		}

		-- Neutralise the process-exit path so the action is safe to run inline.
		local saved_exit    = os.exit
		local saved_doAfter = _G.hs.timer.doAfter
		local exit_scheduled = false
		os.exit = function() error("os.exit must not run during the test") end
		_G.hs.timer.doAfter = function(_delay, _fn) exit_scheduled = true end  -- record, never fire

		local ok = pcall(Actions.execute_single, "script_quit")

		os.exit = saved_exit
		_G.hs.timer.doAfter = saved_doAfter
		package.loaded["platform.remap"] = nil

		helpers.assert_true(ok, "executing script_quit must not raise")
		helpers.assert_eq(killed.count, 1)  -- Karabiner torn down exactly once
		helpers.assert_true(exit_scheduled, "the quit must still schedule the process exit afterwards")
	end)

	helpers.it("also terminates the MLX server + orphan helper processes (F-MED-7)", function()
		-- os.exit(0) bypasses hs.shutdownCallback where the MLX/orphan kills live,
		-- so script_quit must perform the identical teardown or the mlx_lm.server
		-- keeps holding GPU memory + the MLX port and the helper processes orphan.
		local mlx_stopped, helpers_killed, orphan_killed = 0, 0, 0
		package.loaded["platform.remap"] = { kill = function() end }
		package.loaded["ui.menu.menu_llm"] = {
			stop_mlx_server            = function() mlx_stopped = mlx_stopped + 1 end,
			terminate_helper_processes = function() helpers_killed = helpers_killed + 1 end,
			-- stop_mlx_server only kills the in-process wrapper; the detached
			-- mlx_lm.server (own process group) needs this explicit pgrep/lsof sweep
			-- or script_quit leaks the GPU-resident server + the MLX port (F-M7).
			terminate_orphan_mlx_server = function() orphan_killed = orphan_killed + 1 end,
		}

		local saved_exit    = os.exit
		local saved_doAfter = _G.hs.timer.doAfter
		os.exit = function() error("os.exit must not run during the test") end
		_G.hs.timer.doAfter = function(_delay, _fn) end  -- record-never-fire

		local ok = pcall(Actions.execute_single, "script_quit")

		os.exit = saved_exit
		_G.hs.timer.doAfter = saved_doAfter
		package.loaded["platform.remap"] = nil
		package.loaded["ui.menu.menu_llm"] = nil

		helpers.assert_true(ok, "executing script_quit must not raise")
		helpers.assert_eq(mlx_stopped, 1, "script_quit must stop the MLX server (os.exit bypasses the shutdown callback)")
		helpers.assert_eq(helpers_killed, 1, "script_quit must terminate the orphan helper processes")
		helpers.assert_eq(orphan_killed, 1, "script_quit must reap the detached mlx_lm.server (pgrep/lsof sweep) — F-M7")
	end)
end)

helpers.describe("menu_llm.terminate_orphan_mlx_server reaps the detached server", function()
	-- The real menu_llm pulls in the WebView download window (needs a rich hs stub),
	-- so the pgrep/lsof sweep is pinned at source. The script_quit describe above
	-- already proves the action invokes terminate_orphan_mlx_server behaviorally.
	helpers.it("source: defines terminate_orphan_mlx_server with the pgrep + lsof sweep", function()
		-- Selected by a declaration unique to ui/menu/menu_llm/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function format_shortcut_title")
		helpers.assert_true(src ~= nil, "ui/menu/menu_llm/init.lua source must be locatable")
		local idx = src:find("function M.terminate_orphan_mlx_server", 1, true)
		helpers.assert_true(idx ~= nil, "menu_llm must define terminate_orphan_mlx_server")
		local body = src:sub(idx, idx + 600)
		helpers.assert_true(body:find("pgrep -f 'mlx_lm.*server'", 1, true) ~= nil,
			"must pgrep-kill the detached mlx_lm.server")
		helpers.assert_true(body:find("lsof -tiTCP:", 1, true) ~= nil,
			"must free the MLX listening port via lsof")
		helpers.assert_true(body:find("get_port", 1, true) ~= nil,
			"must read the port from the single source api_mlx.get_port()")
	end)

	helpers.it("source: the shutdown callback delegates to the shared helper (no inline drift)", function()
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")
		helpers.assert_true(src:find("terminate_orphan_mlx_server", 1, true) ~= nil,
			"hs.shutdownCallback must call the shared terminate_orphan_mlx_server (not an inline sweep)")
	end)
end)
