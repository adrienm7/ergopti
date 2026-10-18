--- tests/unit/infra/lifecycle/test_session_lock.lua

--- ==============================================================================
--- MODULE: Graphical Session Lock Regression
--- DESCRIPTION:
--- Runs the real launcher and daemon bootstrap with external child processes.
--- Kernel flock ownership must disappear with the daemon, including on crash.
--- ==============================================================================

local helpers = require("tests.helpers")
local shell_quote = require("text_utils").shell_quote

helpers.describe("Graphical session lock ownership", function()
	helpers.it("allows direct CLI startup without a launcher marker (session-lock-cli)", function()
		helpers.assert_eq(os.getenv("ERGOPTI_SESSION_LOCK_FD"), nil)
		helpers.assert_eq(require("infra.session_lock").protect(), true)
	end)

	helpers.it("releases the actual lock after daemon exit with a live child (session-lock-native)", function()
		local fixture = helpers.driver_root() .. "/tests/hardware/test_session_lock.py"
		local status = os.execute("python3 " .. shell_quote(fixture))
		helpers.assert_true(status == 0 or status == true, "Native session lock regression failed")
	end)
end)
