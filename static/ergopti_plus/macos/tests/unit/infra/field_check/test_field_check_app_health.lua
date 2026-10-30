--- tests/unit/infra/field_check/test_field_check_app_health.lua

--- ==============================================================================
--- MODULE: Field Run App Health Probe
--- DESCRIPTION:
--- The field run's app health check over scripted ports:
--- 1. the app's own process is measured with ps (resident memory in MB, CPU
---    share), as information, and an unreadable answer fails the memory step;
--- 2. a crash report of the last day, from the driver or from macOS, fails
---    its own step with the count.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = { commands = {}, ps = { 0, "  412736   1,7\n" }, crashes = { driver = 0, system = 0 } }
	local ports = {
		exec = function(executable, args, _, callback)
			world.commands[#world.commands + 1] = executable .. " " .. table.concat(args, " ")
			callback(world.ps[1], world.ps[2], "")
		end,
		pid = function() return 9531 end,
		crash_counts = function() return world.crashes end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("app_health", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("app health probe", function()
	helpers.it("measures this process and passes without recent crash reports", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(world.commands[1], "/bin/ps -o rss=,%cpu= -p 9531")
		helpers.assert_eq(steps.app_rss_mb.value, "403")
		helpers.assert_eq(steps.app_cpu_pct.value, "1.7", "a decimal comma (French locale) is read")
		helpers.assert_eq(steps.driver_crash_reports_24h.value, "0")
	end)

	helpers.it("fails each crash report family with its count", function()
		local ports, world = make_ports()
		world.crashes = { driver = 0, system = 2 }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.system_crash_reports_24h.value, "2")
		helpers.assert_eq(steps.driver_crash_reports_24h.state, "pass")
		world.crashes = { driver = 1, system = 0 }
		helpers.assert_eq(run(ports).driver_crash_reports_24h.state, "fail")
	end)

	helpers.it("fails an unreadable process measure", function()
		local ports, world = make_ports()
		world.ps = { 1, "" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.app_rss_mb.value, "exit_1")
		helpers.assert_eq(steps.app_cpu_pct.state, "skip")
		world.ps = { nil, "" }
		helpers.assert_eq(run(ports).app_rss_mb.value, "timeout")
	end)
end)
