--- tests/unit/infra/field_check/test_field_check_session.lua

--- ==============================================================================
--- MODULE: Field Check, Session Costs and Edge Cases
--- DESCRIPTION:
--- The hardware session's program-answerable lines: the boot's figures, the
--- idle CPU share over a quiet window (failing above its bound) and the FIFO the
--- file system adapter must never open (field-session-checks).
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("field_check_report")
local Session = require("infra.field_check_session")

local function steps_of(report)
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

--- Ports whose clock and CPU advance only when the window's timer fires.
local function idle_ports(cpu_used_ms)
	local clock = { cpu = 1000, now = 50000 }
	return {
		pid = function() return 42 end,
		cpu_ms = function() return clock.cpu end,
		now_ms = function() return clock.now end,
		exec = function(_, _, _, callback) callback(0, "  20480\n") end,
		after = function(seconds, callback)
			clock.now = clock.now + seconds * 1000
			clock.cpu = clock.cpu + cpu_used_ms
			callback()
		end,
		hold_counts = function() return { over_250ms = 0 } end,
		lua_heap_kb = function() return 4096 end,
	}
end

helpers.describe("field check session: costs and edge cases a program can answer (field-session-checks)", function()
	helpers.it("passes an idle share under the bound and fails a spinning driver", function()
		local report = Report.new_report("idle_cost")
		local finished = 0
		Session.idle_cost(idle_ports(30), report, function() finished = finished + 1 end)
		local steps = steps_of(report)
		helpers.assert_eq(finished, 1)
		helpers.assert_eq(steps.idle_cpu_percent.state, Report.STATE_PASS)
		helpers.assert_eq(steps.idle_cpu_percent.value, "0.10")
		helpers.assert_eq(steps.idle_rss_mb.value, "20")
		local spinning = Report.new_report("idle_cost")
		Session.idle_cost(idle_ports(Session.IDLE_WINDOW_SECONDS * 1000 * 0.2), spinning, function() end)
		helpers.assert_eq(steps_of(spinning).idle_cpu_percent.state, Report.STATE_FAIL)
	end)

	helpers.it("names the boot's totals, and fails a boot that never completed", function()
		local report = Report.new_report("boot_cost")
		Session.boot_cost({ boot_facts = function()
			return { complete_ms = 2450.4, cpu_ms = 1800.2, slowest = { { name = "hotstrings", ms = 900.5 } } }
		end }, report, function() end)
		local steps = steps_of(report)
		helpers.assert_eq(steps.boot_complete_ms.value, "2450")
		helpers.assert_eq(steps.boot_slowest_stage_ms.value, "900")
		local unfinished = Report.new_report("boot_cost")
		Session.boot_cost({ boot_facts = function() return {} end }, unfinished, function() end)
		helpers.assert_eq(steps_of(unfinished).boot_complete_ms.state, Report.STATE_FAIL)
	end)

	helpers.it("names the dominant slow segment of the day log, through the awk summary", function()
		local summary = assert(Session.parse_slow_summary(
			"segment keymap.keydown 2 15.75 12.50\nsegment hotstrings.match 1 40.00 40.00\ningest 1 230\nprefs 0 0\n"
				.. "lease_bound 0\nearly_layout 0\n"))
		helpers.assert_eq(summary.segments[1].name, "hotstrings.match")
		helpers.assert_eq(summary.prefs.count, 0)
		helpers.assert_nil(Session.parse_slow_summary("segment x 1 1.00 1.00\n"), "a summary without its totals is refused")
		local report = Report.new_report("slow_lines")
		Session.slow_lines({
			today_log_path = function() return "/logs/today.log" end,
			exec = function(executable, args, _, callback)
				helpers.assert_eq(executable, "/usr/bin/awk")
				helpers.assert_eq(args[2], "/logs/today.log")
				callback(0, "segment keymap.keydown 2 15.75 12.50\ningest 3 230\nprefs 1 88\nlease_bound 2\nearly_layout 0\n")
			end,
		}, report, function() end)
		local steps = steps_of(report)
		helpers.assert_eq(steps.slow_dominant.value, "keymap.keydown")
		helpers.assert_eq(steps.slow_ingest_ticks.value, "3:230")
		helpers.assert_eq(steps.slow_preferences_saves.value, "1:88")
		helpers.assert_eq(steps.log_lease_bound_failures.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.log_lease_bound_failures.value, "2")
		helpers.assert_eq(steps.log_layout_change_before_baseline.state, Report.STATE_PASS)
	end)

	helpers.it("the awk program reads the three line shapes the drivers write", function()
		local awk = io.open("/usr/bin/awk", "rb")
		if not awk then return end
		awk:close()
		local dir = os.tmpname()
		os.remove(dir)
		local log, program = dir .. ".log", dir .. ".awk"
		local function write(path, text)
			local handle = assert(io.open(path, "wb"))
			handle:write(text)
			handle:close()
		end
		write(program, Session.SLOW_LINES_AWK)
		write(log, table.concat({
			"10:00 [WARN] HotPath: Slow keymap.keydown: 12.50 ms own, 14.00 ms total, parent none (0 similar since the last line).",
			"10:01 [WARN] HotPath: Slow keymap.keydown: 3.25 ms own, 4.00 ms total, parent none (2 similar since the last line).",
			"10:02 [WARN] keystats: Slow ingest tick 230 ms (12 ms; entries=4 statements=9).",
			"10:03 [WARN] preferences: Slow preferences save 88 ms (prepare=1 write=80 ms; operations=2).",
			"10:04 [ERROR] remap: Lease-bound input startup failed: lease-stopping.",
			"10:05 [INFO] remap.watchers: Layout poll detected change before its baseline: 'A' → 'B'.",
			"10:06 [INFO] remap.watchers: Layout poll detected change: 'B' → 'C'.",
		}, "\n") .. "\n")
		local pipe = assert(io.popen("/usr/bin/awk -f '" .. program .. "' '" .. log .. "'"))
		local output = pipe:read("*a")
		pipe:close()
		os.remove(log)
		os.remove(program)
		local summary = assert(Session.parse_slow_summary(output), "the awk summary does not parse: " .. output)
		helpers.assert_eq(summary.segments[1].name, "keymap.keydown")
		helpers.assert_eq(summary.segments[1].count, 2)
		helpers.assert_eq(summary.segments[1].worst_ms, 12.5)
		helpers.assert_eq(summary.ingest.worst_ms, 230)
		helpers.assert_eq(summary.prefs.count, 1)
		helpers.assert_eq(summary.lease_bound, 1)
		helpers.assert_eq(summary.early_layout, 1, "only the change before the baseline is the misread")
	end)

	helpers.it("fails a FIFO the adapter opens, and removes its folder", function()
		local commands = {}
		local function ports(guarded)
			return {
				exec = function(executable, args, _, callback)
					commands[#commands + 1] = executable .. " " .. table.concat(args, " ")
					callback(0, "")
				end,
				after = function(_, callback) callback() end,
				fifo = function()
					return {
						dir = "/tmp/f",
						mode = function() return "present", "named pipe" end,
						exists = function() return true end,
						append = function() return not guarded end,
						write = function() return not guarded end,
					}
				end,
			}
		end
		local report = Report.new_report("fifo_safety")
		Session.fifo_safety(ports(true), report, function() end)
		local steps = steps_of(report)
		for _, id in ipairs({ "fifo_created", "fifo_mode", "fifo_exists", "fifo_append_refused", "fifo_write_refused",
			"fifo_kept", "fifo_cleanup" }) do
			helpers.assert_eq(steps[id].state, Report.STATE_PASS, id)
		end
		helpers.assert_eq(commands[#commands], "/bin/rm -rf /tmp/f")
		local regressed = Report.new_report("fifo_safety")
		Session.fifo_safety(ports(false), regressed, function() end)
		helpers.assert_eq(steps_of(regressed).fifo_append_refused.state, Report.STATE_FAIL)
		helpers.assert_eq(steps_of(regressed).fifo_write_refused.state, Report.STATE_FAIL)
	end)
end)
