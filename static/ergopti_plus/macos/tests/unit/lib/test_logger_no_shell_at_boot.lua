--- tests/unit/lib/test_logger_no_shell_at_boot.lua

--- ==============================================================================
--- MODULE: Regression — the logger must not fork a shell on the boot path
--- DESCRIPTION:
--- init_log_path ran `mkdir -p` through ShellRunner, which is fully synchronous
--- (pcall(hs.execute, …)). That is a fork+exec on the boot critical path, paid on
--- every launch, for a directory that already exists on all but the first.
---
--- ROOT CAUSE ENCODED:
--- Asserting the ABSENCE of the harmful operation — zero shell executions —
--- rather than the presence of the replacement. A test that checked "mkdir is
--- called somehow" would pass against either implementation; this one can only
--- pass when nothing shells out.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: configuring the log path spawns no subprocess", function()

	helpers.it("performs zero shell executions", function()
		local execs = {}
		local made  = {}
		local hs_overrides = {
			execute = function(cmd) table.insert(execs, cmd); return "", true end,
			fs = {
				mkdir      = function(p) table.insert(made, p); return true end,
				dir        = function() error("no directory walk expected here") end,
				attributes = function() return nil end,
			},
			timer = { doAfter = function() return { stop = function() end } end },
		}

		package.loaded["infra.logger"] = nil
		local Logger = helpers.load_with_stubs("infra.logger", hs_overrides)
		Logger.init_log_path("/tmp/ergopti_logger_test/", 14)

		helpers.assert_eq(#execs, 0,
			"the log directory must be created in-process; a fork+exec here is paid on every "
			.. "boot for a directory that already exists on all but the first")
		helpers.assert_true(#made > 0,
			"and it must still actually create the directory — asserting only the absence of "
			.. "the shell would pass against a version that creates nothing at all")
	end)

end)
