--- tests/meta/test_init_vscode_bridge_setup_error_logged.lua

--- ==============================================================================
--- MODULE: Regression — vscode_bridge.setup() failure surfaced at the boot call site (F-MED-7)
--- DESCRIPTION:
--- init.lua wired the VS Code caret bridge with a bare
--- `pcall(function() require("infra.vscode_bridge").setup() end)`, discarding
--- BOTH pcall return values. A setup() throw (a failed extension install, a
--- port bind failure, …) vanished with no trace anywhere in the boot log.
---
--- Fix: capture (ok, err) and call Logger.error(...) on failure, so the
--- failure is visible in the unified log like every other boot step.
---
--- init.lua is a top-level boot script with many side effects (hs.reload,
--- eventtap creation, TOML discovery) and is never `require()`d or executed
--- end-to-end by the test suite (see the sibling tests/meta/test_init_*.lua
--- files, all of which are source-position/invariant scans for the same
--- reason). This test follows that established convention: a source scan
--- asserting the pcall's return values are captured into named locals and
--- that the failure branch calls Logger.error referencing vscode_bridge.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_init_src()
	-- Selected by a declaration unique to init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil, "init.lua source must be locatable")
	return src
end

helpers.describe("F-MED-7: vscode_bridge.setup() failure is logged at the boot call site", function()

	helpers.it("the vscode_bridge.setup() call site no longer uses a bare, return-discarding pcall", function()
		local src = read_init_src()

		local setup_pos = src:find('require("infra.vscode_bridge").setup()', 1, true)
		helpers.assert_true(setup_pos ~= nil, "init.lua must call lib.vscode_bridge's setup()")

		-- The old bug pattern: pcall(function() ... setup() ... end) with no
		-- assignment at all — i.e. a bare pcall(...) statement, not `local ok, err = pcall(...)`.
		local window_before = src:sub(math.max(1, setup_pos - 200), setup_pos)
		helpers.assert_true(
			window_before:find("ok_vscode") ~= nil,
			"init.lua must capture the pcall's return values into named locals (e.g. ok_vscode) " ..
			"instead of a bare, return-discarding pcall(...) statement (F-MED-7)")
	end)

	helpers.it("Logger.error is called when vscode_bridge.setup() throws", function()
		local src = read_init_src()

		local setup_pos = src:find('require("infra.vscode_bridge").setup()', 1, true)
		helpers.assert_true(setup_pos ~= nil, "init.lua must call lib.vscode_bridge's setup()")

		-- Logger.error must appear shortly after the pcall, inside the same guard block.
		local window_after = src:sub(setup_pos, math.min(#src, setup_pos + 400))
		local log_pos = window_after:find("Logger.error", 1, true)
		helpers.assert_true(log_pos ~= nil,
			"init.lua must call Logger.error(...) when vscode_bridge.setup() throws (F-MED-7)")

		local log_line = window_after:sub(log_pos, log_pos + 120)
		helpers.assert_true(log_line:find("vscode", 1, true) ~= nil or log_line:find("VS Code", 1, true) ~= nil,
			"the Logger.error message must mention the VS Code bridge so the failure is identifiable in the log")
	end)

	helpers.it("a false VS Code bridge setup rolls back and aborts root initialization", function()
		local src = read_init_src()
		local guard_pos = src:find("if not ok_vscode or vscode_result ~= true then", 1, true)
		helpers.assert_true(guard_pos ~= nil,
			"root initialization must treat an exact false setup result as failure")
		local guard_window = src:sub(guard_pos, math.min(#src, guard_pos + 1200))
		local rollback_pos = guard_window:find("stop_server()", 1, true)
		local abort_pos = guard_window:find('error("VS Code caret bridge setup did not commit")', 1, true)
		helpers.assert_true(rollback_pos ~= nil,
			"root initialization must retry exact VS Code server cleanup before aborting")
		helpers.assert_true(abort_pos ~= nil and rollback_pos < abort_pos,
			"root initialization must abort only after attempting bridge rollback")
	end)
end)
