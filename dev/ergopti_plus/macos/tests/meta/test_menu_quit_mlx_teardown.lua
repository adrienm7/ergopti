--- tests/meta/test_menu_quit_mlx_teardown.lua

--- ==============================================================================
--- MODULE: Menubar Quit Shares the Root Teardown
--- DESCRIPTION:
--- The menu formerly duplicated MLX/keylogger cleanup before an unconditional
--- os.exit. It now delegates to the exact-fence coordinator; one root teardown
--- owns every sibling and therefore cannot drift between quit entry points.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu/init.lua: Quit delegates full teardown after the fence", function()
	helpers.it("the menu delegates and the root teardown owns both MLX cleanup calls", function()
		local menu_src = helpers.read_driver_source("local function safe_require")
		local init_src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(menu_src ~= nil and init_src ~= nil)
		local quit_pos = menu_src:find("quit%s*=%s*function%(%)")
		local next_pos = menu_src:find("open_logs%s*=", quit_pos or 1)
		helpers.assert_true(quit_pos ~= nil and next_pos ~= nil)
		local quit_body = menu_src:sub(quit_pos, next_pos - 1)
		helpers.assert_true(quit_body:find("TerminationCoordinator.request_exit", 1, true) ~= nil)
		helpers.assert_true(quit_body:find("terminate_helper_processes", 1, true) == nil)
		helpers.assert_true(quit_body:find("terminate_orphan_mlx_server", 1, true) == nil)

		local teardown_at = init_src:find("local function teardown_all_resources", 1, true)
		local shutdown_at = init_src:find("local function shutdown_all_resources", 1, true)
		helpers.assert_true(teardown_at ~= nil and shutdown_at ~= nil)
		local teardown = init_src:sub(teardown_at, shutdown_at - 1)
		helpers.assert_true(teardown:find("terminate_helper_processes", 1, true) ~= nil)
		helpers.assert_true(teardown:find("terminate_orphan_mlx_server", 1, true) ~= nil)
	end)
end)
