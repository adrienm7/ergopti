--- tests/meta/test_menu_quit_mlx_teardown.lua

--- ==============================================================================
--- MODULE: Regression — menubar Quit calls full MLX teardown before os.exit (M-11)
--- DESCRIPTION:
--- os.exit(0) bypasses hs.shutdownCallback where terminate_helper_processes() and
--- terminate_orphan_mlx_server() live. The menubar Quit action is a THIRD quit path
--- (beside shutdownCallback and gesture script_quit) that must replicate that teardown
--- itself. Without it the detached mlx_lm.server + helper daemons survive
--- indefinitely after a menubar Quit.
---
--- Fix: call both functions before os.exit(0) in the Quit action body.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu/init.lua: Quit action calls MLX teardown before os.exit (M-11)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/menu/init.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "ui/menu/init.lua must be readable")
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("Quit action body calls terminate_orphan_mlx_server before os.exit", function()
		local src = read_src()
		-- Find the position of the quit action and the os.exit call
		local quit_pos    = src:find("quit%s*=%s*function%(%)") or src:find('quit%s+=%s+function%(%)')
		local os_exit_pos = src:find("os%.exit%(0%)", quit_pos or 1)
		local mlx_pos     = src:find("terminate_orphan_mlx_server", quit_pos or 1)
		helpers.assert_true(quit_pos ~= nil, "quit action must exist in ui/menu/init.lua")
		helpers.assert_true(os_exit_pos ~= nil, "os.exit(0) must exist after quit action")
		helpers.assert_true(mlx_pos ~= nil and mlx_pos < os_exit_pos,
			"terminate_orphan_mlx_server must be called before os.exit(0) in the Quit action")
	end)

	helpers.it("Quit action body calls terminate_helper_processes before os.exit", function()
		local src = read_src()
		local quit_pos    = src:find("quit%s*=%s*function%(%)") or src:find('quit%s+=%s+function%(%)')
		local os_exit_pos = src:find("os%.exit%(0%)", quit_pos or 1)
		local hp_pos      = src:find("terminate_helper_processes", quit_pos or 1)
		helpers.assert_true(quit_pos ~= nil, "quit action must exist in ui/menu/init.lua")
		helpers.assert_true(os_exit_pos ~= nil, "os.exit(0) must exist after quit action")
		helpers.assert_true(hp_pos ~= nil and hp_pos < os_exit_pos,
			"terminate_helper_processes must be called before os.exit(0) in the Quit action")
	end)
end)
