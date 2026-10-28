--- tests/unit/adapters/processes/test_shell_runner_process_phase.lua

--- ==============================================================================
--- MODULE: ShellRunner child-process phase regression tests
--- DESCRIPTION:
--- Every child the runner reports is timed as the phase process.<program>, the
--- phase the Linux driver also records. Only the asynchronous task path did so
--- before: a synchronous exec() that blocked the main thread for a second left
--- no phase, so the periodic summary hid the slowest kind of child. The name is
--- the sanitised program basename, never the command line.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads ShellRunner over an hs.execute double, with the real PhaseStats.
--- @return table ShellRunner, table PhaseStats
local function load_runner()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("adapters.shell_runner", {
		execute = function() return "out\n", true, "exit", 0 end,
	})
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.phase_stats"] = nil
	package.loaded["adapters.shell_runner"] = nil
	local ShellRunner = require("adapters.shell_runner")
	local PhaseStats = require("infra.phase_stats")
	PhaseStats.reset()
	return ShellRunner, PhaseStats
end

helpers.describe("ShellRunner: synchronous children are timed as process.<program>", function()
	helpers.it("records one phase per exec() under the program basename", function()
		local ShellRunner, PhaseStats = load_runner()
		helpers.assert_eq(ShellRunner.exec("/bin/echo out"), "out\n")
		local figures = PhaseStats.figures("process.echo")
		helpers.assert_true(figures ~= nil, "a synchronous child must leave a process phase")
		helpers.assert_eq(figures.n, 1)
	end)

	helpers.it("never puts an argument into the phase name", function()
		local ShellRunner, PhaseStats = load_runner()
		ShellRunner.exec("/bin/echo secret-argument-4711")
		helpers.assert_eq(PhaseStats.figures("process.secret-argument-4711"), nil)
		helpers.assert_true(PhaseStats.figures("process.echo") ~= nil)
	end)
end)
