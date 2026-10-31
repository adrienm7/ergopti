--- tests/unit/infra/field_check/test_field_check_app_health.lua

--- ==============================================================================
--- MODULE: Field Run App Health Probe
--- DESCRIPTION:
--- The field run's app health check over scripted ports:
--- 1. the app's own process is measured with ps (resident memory in MB, CPU
---    share), as information, and an unreadable answer fails the memory step;
--- 2. a crash report written since the current app start (the launcher's
---    elapsed time from ps) by the driver, or by macOS for one of this app's
---    processes, fails, naming each process and listing the newest with its
---    kind; an earlier start's reports and other apps' reports are only
---    counted (the 2026-10-30 20:51 run read a bare system count of 11, the
---    2026-10-31 run failed on 13 reports of replaced builds).
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local function make_ports()
	local world = { commands = {}, ps = { 0, "  412736   1,7\n" }, etime = { 0, "   01:02:05\n" },
		crashes = { driver = 0, owned = {}, other = 4 } }
	local ports = {
		exec = function(executable, args, _, callback)
			world.commands[#world.commands + 1] = executable .. " " .. table.concat(args, " ")
			local answer = args[2] == "etime=" and world.etime or world.ps
			callback(answer[1], answer[2], "")
		end,
		pid = function() return 9531 end,
		app_start_pid = function() return 9400 end,
		now = function() return 1000000 end,
		crash_counts = function(since)
			world.since = since
			return world.crashes
		end,
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
		helpers.assert_eq(world.commands[1], "/bin/ps -o etime= -p 9400")
		helpers.assert_eq(world.commands[2], "/bin/ps -o rss=,%cpu= -p 9531")
		helpers.assert_eq(steps.app_uptime_s.value, "3725")
		helpers.assert_eq(world.since, 1000000 - 3725 - 1, "reports are judged from the app start")
		helpers.assert_eq(steps.app_rss_mb.value, "403")
		helpers.assert_eq(steps.app_cpu_pct.value, "1.7", "a decimal comma (French locale) is read")
		helpers.assert_eq(steps.driver_crash_reports_since_start.value, "0")
	end)

	helpers.it("fails the app's crash reports by process and only counts the others", function()
		local ports, world = make_ports()
		world.crashes = { driver = 0, other = 9, owned = {
			{ process = "ergoptiplus", kind = "crash:exc_crash:sigkill:codesigning" },
			{ process = "ollama", kind = "crash:exc_bad_access:sigsegv" },
			{ process = "ergoptiplus", kind = "hang" },
			{ process = "python", kind = "crash" },
		} }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.app_crash_reports_since_start.value, "ergoptiplus:2+ollama:1+python:1")
		helpers.assert_eq(steps.app_crash_1.value, "ergoptiplus:crash:exc_crash:sigkill:codesigning")
		helpers.assert_eq(steps.app_crash_3.value, "ergoptiplus:hang")
		helpers.assert_nil(steps.app_crash_4)
		helpers.assert_eq(steps.other_crash_reports_24h.state, "info")
		helpers.assert_eq(steps.other_crash_reports_24h.value, "9")
		world.crashes = { driver = 1, owned = {}, other = 0 }
		steps, result = run(ports)
		helpers.assert_eq(steps.driver_crash_reports_since_start.state, "fail")
		helpers.assert_eq(steps.app_crash_reports_since_start.state, "pass")
	end)

	helpers.it("counts an earlier start's crash reports without failing (crashes-since-app-start)", function()
		local ports, world = make_ports()
		world.crashes = { driver = 0, driver_earlier = 2, other = 0, owned = {},
			earlier = { ergoptiplus = 13, ollama = 1 } }
		local steps, result = run(ports)
		helpers.assert_true(result.passed, "a replaced build's reports are history, not this start's health")
		helpers.assert_eq(steps.app_crash_reports_since_start.state, "pass")
		helpers.assert_eq(steps.app_crash_reports_earlier_24h.state, "info")
		helpers.assert_eq(steps.app_crash_reports_earlier_24h.value, "ergoptiplus:13+ollama:1")
		helpers.assert_eq(steps.driver_crash_reports_earlier_24h.value, "2")
	end)

	helpers.it("parses ps elapsed times and fails an unreadable app start", function()
		local Probes
		helpers.with_stub_scope(MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.field_check_probes"] = nil
			Probes = require("infra.field_check_probes")
		end)
		helpers.assert_eq(Probes.parse_elapsed("   00:07\n"), 7)
		helpers.assert_eq(Probes.parse_elapsed("12:34"), 754)
		helpers.assert_eq(Probes.parse_elapsed("01:00:00"), 3600)
		helpers.assert_eq(Probes.parse_elapsed("2-03:04:05"), 2 * 86400 + 3 * 3600 + 4 * 60 + 5)
		helpers.assert_nil(Probes.parse_elapsed(""))
		helpers.assert_nil(Probes.parse_elapsed("7"))
		local ports, world = make_ports()
		world.etime = { 1, "" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.app_uptime_s.value, "exit_1")
		helpers.assert_nil(world.since, "an unknown start judges the whole day")
	end)

	helpers.it("passes with other apps' crash reports only", function()
		local ports, world = make_ports()
		world.crashes = { driver = 0, owned = {}, other = 11 }
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.other_crash_reports_24h.value, "11")
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
