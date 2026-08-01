--- tests/meta/test_vscode_bridge_lifecycle_wired.lua

--- ==============================================================================
--- MODULE: Regression — vscode_bridge.setup() and stop_server() wired in boot (M-10)
--- DESCRIPTION:
--- Before M-10, infra/vscode_bridge.lua was required by the tooltip renderer but
--- M.setup() (the only path that installs the extension and starts the HTTP server
--- on :7878) had no caller in the macOS boot tree. The bridge was effectively dead
--- in production: get_caret() always returned nil because start_server() never ran.
---
--- Fix: init.lua calls require("infra.vscode_bridge").setup() after menu.start(), and
--- the shutdownCallback calls stop_server().
---
--- Tests (source scan — no hs environment needed):
---   1. init.lua calls vscode_bridge.setup() (setup is wired into boot).
---   2. init.lua's shutdownCallback calls stop_server() (teardown is wired).
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel_path)
	local path = helpers.driver_root() .. rel_path
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel_path .. " must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end





-- ======================================================================
-- ======================================================================
-- ======= 1/ init.lua wires vscode_bridge.setup() on boot (M-10) =======
-- ======================================================================
-- ======================================================================

helpers.describe("M-10: vscode_bridge lifecycle wired in init.lua", function()

	helpers.it("init.lua calls vscode_bridge.setup() after menu.start()", function()
		local src = read_src("init.lua")

		helpers.assert_true(src:find("vscode_bridge", 1, true) ~= nil,
			"init.lua must reference vscode_bridge to wire the bridge on boot (M-10)")

		helpers.assert_true(src:find("%.setup()", 1, true) ~= nil or
			src:find(".setup()", 1, true) ~= nil,
			"init.lua must call .setup() on the bridge so the HTTP server starts")

		-- setup() must appear AFTER menu.start (tooltip subsystem must be up first).
		--
		-- Anchored on the SETUP CALL, not on the first mention of the module. The
		-- shutdown callback also requires vscode_bridge — for stop_server — and it
		-- is armed early in boot, so the first mention is the teardown's and says
		-- nothing about when the server starts.
		local menu_pos  = src:find("menu.start(", 1, true)
		local setup_pos = src:find('require("infra.vscode_bridge").setup()', 1, true)
		helpers.assert_true(menu_pos ~= nil, "init.lua must call menu.start()")
		helpers.assert_true(setup_pos ~= nil, "init.lua must call vscode_bridge.setup()")
		helpers.assert_true(setup_pos > menu_pos,
			"vscode_bridge.setup() must be called after menu.start() in init.lua")
	end)

	helpers.it("init.lua shutdownCallback calls stop_server()", function()
		local src = read_src("init.lua")
		helpers.assert_true(src:find("stop_server", 1, true) ~= nil,
			"init.lua shutdownCallback must call stop_server() to clean up the bridge HTTP server (M-10)")
	end)
end)
