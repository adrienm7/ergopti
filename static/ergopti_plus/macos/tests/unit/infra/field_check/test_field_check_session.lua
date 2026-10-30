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
