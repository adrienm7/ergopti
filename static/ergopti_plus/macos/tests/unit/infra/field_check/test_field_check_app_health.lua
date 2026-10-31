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
---    2026-10-31 run failed on 13 reports of replaced builds);
--- 3. where the resident memory goes (ledger L32: 843 MB with no breakdown):
---    the physical footprint and the largest resident regions of vmmap's
---    summary, and the Lua heap, as information; an unreadable vmmap is a
---    named skip.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports; `world` records every command.
--- @return table ports, table world
local VMMAP = table.concat({
	"Process:         Hammerspoon [9531]",
	"Physical footprint:         212.3M",
	"Physical footprint (peak):  1.1G",
	"",
	"                                VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION ",
	"REGION TYPE                        SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced) ",
	"===========                     ======= ========    =====  ======= ========   ======    =====  ======= ",
	"Activity Tracing                   256K      32K      32K       0K       0K      32K       0K        1 ",
	"IOSurface                         48.5M    48.5M    48.5M       0K       0K       0K       0K       12 ",
	"MALLOC_SMALL                      72.0M    50.2M    50.2M     144K       0K       0K       0K        9         see MALLOC ZONE table below",
	"WebKit Malloc                    192.0M    20.0M    20.0M       0K       0K       0K       0K        4 ",
	"__TEXT                           512.0M   300.1M       0K       0K       0K       0K       0K      620 ",
	"mapped file                        1.2G     3.0M       0K       0K       0K       0K       0K       88 ",
	"MALLOC_TINY                       16.0M    10.0M    10.0M       0K       0K       0K       0K        3 ",
	"===========                     ======= ========    =====  ======= ========   ======    =====  ======= ",
	"TOTAL                              2.1G   432.0M   128.8M     144K       0K      32K       0K      737 ",
	"",
	"                                 VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION",
	"MALLOC ZONE                         SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT",
	"===========                      =======  =========  =========  =========  =========  =========  =========  ======  ======",
	"DefaultMallocZone_0x100000000       88.0M      60.2M      60.2M       144K     120000      40.0M      20.3M     34%      12",
}, "\n") .. "\n"

local function make_ports()
	local world = { commands = {}, ps = { 0, "  412736   1,7\n" }, etime = { 0, "   01:02:05\n" },
		vmmap = { 0, VMMAP }, heap_kb = 51200,
		crashes = { driver = 0, owned = {}, other = 4 } }
	local ports = {
		exec = function(executable, args, _, callback)
			world.commands[#world.commands + 1] = executable .. " " .. table.concat(args, " ")
			local answer = executable == "/usr/bin/vmmap" and world.vmmap
				or args[2] == "etime=" and world.etime or world.ps
			callback(answer[1], answer[2], "")
		end,
		lua_heap_kb = function() return world.heap_kb end,
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

	helpers.it("names where the resident memory goes (resident-breakdown)", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed, "the breakdown is information")
		helpers.assert_eq(world.commands[3], "/usr/bin/vmmap --summary 9531")
		helpers.assert_eq(steps.memory_footprint_mb.state, "info")
		helpers.assert_eq(steps.memory_footprint_mb.value, "212")
		helpers.assert_eq(steps.memory_footprint_peak_mb.value, "1126")
		helpers.assert_eq(steps.memory_resident_total_mb.value, "432")
		helpers.assert_eq(steps.memory_region_1.value, "__TEXT:300")
		helpers.assert_eq(steps.memory_region_2.value, "MALLOC_SMALL:50")
		helpers.assert_eq(steps.memory_region_3.value, "IOSurface:48")
		helpers.assert_eq(steps.memory_region_4.value, "WebKit_Malloc:20")
		helpers.assert_eq(steps.memory_region_5.value, "MALLOC_TINY:10")
		helpers.assert_nil(steps.memory_region_6, "the malloc zone table is not a region row")
		helpers.assert_eq(steps.lua_heap_mb.value, "50.0")
	end)

	helpers.it("skips an unreadable vmmap by name and still measures the Lua heap", function()
		local ports, world = make_ports()
		world.vmmap = { 1, "vmmap cannot examine process 9531\n" }
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.memory_footprint_mb.state, "skip")
		helpers.assert_eq(steps.memory_footprint_mb.value, "exit_1")
		helpers.assert_nil(steps.memory_region_1)
		helpers.assert_eq(steps.lua_heap_mb.value, "50.0")
		world.vmmap = { 0, "no summary here\n" }
		helpers.assert_eq(run(ports).memory_footprint_mb.value, "unparsed")
	end)
end)
