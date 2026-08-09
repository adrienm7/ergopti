--- tests/meta/test_menu_quit_karabiner_ownership.lua

--- ==============================================================================
--- MODULE: Menubar Quit Uses the Exact-Fence Coordinator
--- DESCRIPTION:
--- Menubar Quit must delegate a stable reason to the root lifecycle transaction.
--- It may not call os.exit, tear down consumers, or acquire stock/personal
--- Karabiner process authority itself.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quit_action_body()
	local source, err = helpers.read_driver_unit("local function safe_require")
	helpers.assert_true(source ~= nil, "ui.menu.init source must be unique: " .. tostring(err))
	local start_at = source:find("quit%s*=%s*function%(%)")
	local end_at = source:find("open_logs%s*=", start_at or 1)
	helpers.assert_true(start_at ~= nil and end_at ~= nil, "quit action must be locatable")
	return source:sub(start_at, end_at - 1)
end

helpers.describe("menu Quit uses exact lease revocation", function()
	helpers.it("requests one coordinated menu_quit exit", function()
		local body = quit_action_body()
		helpers.assert_true(body:find('TerminationCoordinator.request_exit("menu_quit", 0)', 1, true) ~= nil)
		helpers.assert_true(body:find("os.exit", 1, true) == nil,
			"only the root coordinator may exit after STOPPED")
		helpers.assert_true(body:find("karabiner.shutdown", 1, true) == nil,
			"the menu must not duplicate the lease transaction")
	end)

	helpers.it("contains no direct Karabiner reset or stock-process authority", function()
		local body = quit_action_body()
		for _, retired in ipairs({
			"run_total_reset", "is_hs_owned_bridge", "KILL_CMD",
			"karabiner.kill", "pgrep", "pkill", "launchctl",
		}) do
			helpers.assert_true(body:find(retired, 1, true) == nil,
				"menu Quit must not regain stock-process authority: " .. retired)
		end
	end)
end)
