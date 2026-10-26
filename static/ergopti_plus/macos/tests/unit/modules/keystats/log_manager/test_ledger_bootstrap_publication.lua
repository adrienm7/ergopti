--- tests/unit/modules/keystats/log_manager/test_ledger_bootstrap_publication.lua

--- ==============================================================================
--- MODULE: Initial Ledger Publication Tests
--- DESCRIPTION:
--- Portable physical FILE refusals must leave no canonical partial header and
--- admit one complete SQLite event after retry. Native Linux pressure is a
--- separate mandatory Common control, not a substitute for Darwin execution.
--- ==============================================================================

local helpers = require("tests.helpers")
local CommandLines = require("tests.support.command_lines")
local shell_quote = require("text_utils").shell_quote

helpers.describe("initial canonical ledger publication", function()
	helpers.it("(ledger-bootstrap-publication) retries refused write and close before public admission", function()
		local root = helpers.driver_root() .. "../../.."
		local lines = CommandLines.read("python3 "
			.. shell_quote(root .. "/tools/diagnostics/hs274_ledger_bootstrap_test.py") .. " 2>&1")
		helpers.assert_true(table.concat(lines, "\n"):find("Ran 2 tests", 1, true) ~= nil,
			"both physical portable refusal cases must run, not merely import their fixture")
	end)
end)
