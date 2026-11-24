--- _shared/tests/lua/diagnostics/run_all_contract.lua

--- Exercises the Debug menu's « Test everything » sequencer
--- (_shared/diagnostics/engine/field_check/run_all.lua) under a driver's suite:
--- the plan resolves each step's check and deadline from the field run
--- declaration and its field points from the coverage file; the run starts the
--- checks one after the other from fresh timer turns; a check that is refused,
--- raises or misses its deadline is a failed entry and the sequence goes on; the
--- report names each check's verdict, step and field points and the rows to run
--- separately.
return function(helpers)
	local RunAll = require("diagnostics.engine.field_check.run_all")
	local Report = require("diagnostics.engine.field_check.report")

	local STEPS = {
		{ id = "field_network", kind = "field_check", check = "network", deadline_seconds = 60 },
		{ id = "field_composer", kind = "field_check", check = "composer", deadline_seconds = 90 },
		{ id = "field_boot_cost", kind = "field_check", check = "boot_cost", deadline_seconds = 10 },
		{ id = "driver_reload", kind = "reload", deadline_seconds = 60 },
		{ id = "key_accounting", kind = "field_check", check = "typing_selftest", deadline_seconds = 30 },
	}
	local COVERAGE = { points = {
		{ id = "pac_real", checks = { { step = "field_network" }, { step = "field_network", report = { "x" } } } },
		{ id = "composer_l52", checks = { { step = "field_composer" } } },
		{ id = "l42_off_company_network", checks = { { step = "field_network" } } },
		{ id = "dropped_letters", checks = { { step = "key_accounting" } } },
		{ id = "untestable", checks = {}, not_testable = "needs a person" },
	} }

	local function declaration(run, separate)
		return { platforms = { test = { run = run, separate = separate or {} } } }
	end

	--- A timer queue whose turns the test drains by hand.
	local function clock()
		local world = { now = 0, queue = {}, cancelled = {} }
		function world.after(seconds, fn)
			local handle = { at = world.now + seconds, fn = fn }
			table.insert(world.queue, handle)
			return handle
		end
		function world.cancel(handle) world.cancelled[handle] = true end
		--- Runs every due turn, advancing to `until_time` at most.
		function world.drain(until_time)
			while true do
				local best, best_index = nil, nil
				for index, handle in ipairs(world.queue) do
					if not world.cancelled[handle] and handle.at <= until_time
						and (best == nil or handle.at < best.at) then best, best_index = handle, index end
				end
				if best == nil then return end
				table.remove(world.queue, best_index)
				world.now = math.max(world.now, best.at)
				best.fn()
			end
		end
		return world
	end

	local function report_of(check, state, not_run)
		local report = Report.new_report(check)
		report.step("probe", state)
		if not_run then report.not_run(not_run) end
		return report.result()
	end

	local translate = function(key) return "[" .. key .. "]" end

	helpers.describe("test everything: the plan", function()
		helpers.it("takes each step's check and deadline from the field run and its points from the coverage", function()
			local plan = RunAll.plan(declaration(
				{ { step = "field_network", row = "field_check_network" }, { step = "field_boot_cost" } },
				{ { row = "field_check_key_accounting", step = "key_accounting" }, { row = "hook_probe" } }),
				"test", STEPS, COVERAGE)
			helpers.assert_eq(#plan.run, 2)
			helpers.assert_eq(plan.run[1].check, "network")
			helpers.assert_eq(plan.run[1].deadline_seconds, 60)
			helpers.assert_eq(plan.run[1].row, "field_check_network")
			helpers.assert_eq(table.concat(plan.run[1].points, ","), "pac_real,l42_off_company_network")
			helpers.assert_eq(#plan.run[2].points, 0)
			helpers.assert_eq(plan.separate[1].points[1], "dropped_letters")
			helpers.assert_eq(#plan.separate[2].points, 0)
		end)

		helpers.it("refuses an unknown step, a step that is not a field check and a missing platform", function()
			helpers.assert_throws(function() RunAll.plan(declaration({ { step = "nope" } }), "test", STEPS, nil) end)
			helpers.assert_throws(function() RunAll.plan(declaration({ { step = "driver_reload" } }), "test", STEPS, nil) end)
			helpers.assert_throws(function() RunAll.plan(declaration({}), "other", STEPS, nil) end)
			helpers.assert_throws(function() RunAll.plan(declaration({}, { { row = "x", step = "nope" } }), "test", STEPS, nil) end)
		end)
	end)

	helpers.describe("test everything: the run", function()
		local function plan_of(steps)
			local run = {}
			for _, step in ipairs(steps) do table.insert(run, { step = step }) end
			return RunAll.plan(declaration(run, { { row = "hook_probe" } }), "test", STEPS, COVERAGE)
		end

		helpers.it("runs the checks one after the other, each from a fresh turn, and settles once", function()
			local world, started, done = clock(), {}, {}
			local pending = {}
			local depth = 0
			RunAll.run(plan_of({ "field_network", "field_composer" }), {
				after = world.after, cancel = world.cancel,
				start = function(entry, on_result)
					helpers.assert_eq(depth, 0, "a check started inside another's callback")
					table.insert(started, entry.check)
					pending[entry.check] = on_result
					return true
				end,
			}, function(summary) table.insert(done, summary) end)
			helpers.assert_eq(#started, 0, "the first check waits for a timer turn")
			world.drain(0)
			helpers.assert_eq(table.concat(started, ","), "network")
			depth = 1
			pending.network(report_of("network", Report.STATE_PASS))
			depth = 0
			helpers.assert_eq(#started, 1, "the next check waits for its own turn")
			world.drain(0)
			helpers.assert_eq(table.concat(started, ","), "network,composer")
			pending.composer(report_of("composer", Report.STATE_FAIL))
			pending.composer(report_of("composer", Report.STATE_PASS))
			world.drain(1000)
			helpers.assert_eq(#done, 1)
			helpers.assert_true(not done[1].passed)
			helpers.assert_eq(done[1].entries[1].verdict, "pass")
			helpers.assert_eq(done[1].entries[2].verdict, "fail")
		end)

		helpers.it("records a refused, a raising and a late check as failed and goes on", function()
			local world, done, abandoned = clock(), nil, {}
			local late
			RunAll.run(plan_of({ "field_network", "field_composer", "field_boot_cost", "key_accounting" }), {
				after = world.after, cancel = world.cancel,
				abandon = function(entry) table.insert(abandoned, entry.check) end,
				start = function(entry, on_result)
					if entry.check == "network" then return false end
					if entry.check == "composer" then error("boom") end
					if entry.check == "boot_cost" then late = on_result; return true end
					on_result(report_of(entry.check, Report.STATE_INFO, "not_granted"))
					return true
				end,
			}, function(summary) done = summary end)
			world.drain(9)
			helpers.assert_nil(done, "the late check still has time")
			world.drain(10)
			helpers.assert_eq(table.concat(abandoned, ","), "boot_cost")
			late(report_of("boot_cost", Report.STATE_PASS))
			world.drain(1000)
			helpers.assert_not_nil(done)
			local codes = {}
			for _, entry in ipairs(done.entries) do table.insert(codes, entry.verdict .. ":" .. tostring(entry.code)) end
			helpers.assert_eq(table.concat(codes, " "), "fail:refused fail:raised fail:timeout skip:not_granted")
			helpers.assert_true(not done.passed)
			helpers.assert_eq(RunAll.format_log_line(done),
				"check=all verdict=fail checks=4 field_network=fail:refused field_composer=fail:raised "
				.. "field_boot_cost=fail:timeout key_accounting=skip:not_granted separate=1")
		end)

		helpers.it("passes when every check passed, and cancels the deadline of a check that answered", function()
			local world, done = clock(), nil
			RunAll.run(plan_of({ "field_network" }), {
				after = world.after, cancel = world.cancel,
				start = function(entry, on_result) on_result(report_of(entry.check, Report.STATE_PASS)); return true end,
			}, function(summary) done = summary end)
			world.drain(0)
			helpers.assert_true(done.passed)
			local live = 0
			for _, handle in ipairs(world.queue) do if not world.cancelled[handle] then live = live + 1 end end
			helpers.assert_eq(live, 0, "a settled check leaves no deadline behind")
		end)
	end)

	helpers.describe("test everything: the report", function()
		helpers.it("shows a developer field run check's steps as their closed codes", function()
			local world, done = clock(), nil
			RunAll.run(RunAll.plan(declaration({ { step = "field_boot_cost" } }), "test", STEPS, nil), {
				after = world.after, cancel = world.cancel,
				start = function(_, on_result)
					local report = Report.new_report("boot_cost")
					report.step("boot_complete_ms", Report.STATE_INFO, 3010)
					report.step("boot_budget", Report.STATE_FAIL)
					on_result(report.result())
					return true
				end,
			}, function(summary) done = summary end)
			world.drain(1000)
			local text = RunAll.format_text(done, function(key)
				if key == "common.label_value" then return "{1} : {2}" end
				return "[" .. key .. "]"
			end)
			helpers.assert_contains(text, "❌ field_boot_cost\n    ℹ️ boot_complete_ms : 3010\n    ❌ boot_budget")
			helpers.assert_true(not text:find("field_check.step.", 1, true), "no step label key is looked up")
		end)

		helpers.it("names each check's verdict, step and field points, its own steps, then the rows to run separately", function()
			local world, done = clock(), nil
			local plan = RunAll.plan(declaration(
				{ { step = "field_network", row = "field_check_network" }, { step = "field_boot_cost" } },
				{ { row = "field_check_key_accounting", step = "key_accounting" } }), "test", STEPS, COVERAGE)
			RunAll.run(plan, {
				after = world.after, cancel = world.cancel,
				start = function(entry, on_result)
					if entry.check == "network" then on_result(report_of("network", Report.STATE_PASS)) end
					return true
				end,
			}, function(summary) done = summary end)
			world.drain(1000)
			local text = RunAll.format_text(done, translate)
			helpers.assert_contains(text, "[field_check.all.verdict_fail]")
			helpers.assert_contains(text, "✅ [menu.debug.field_check_network] — field_network, pac_real, l42_off_company_network")
			helpers.assert_contains(text, "    ✅ [field_check.step.probe]")
			helpers.assert_contains(text, "❌ field_boot_cost\n    [field_check.all.timeout]")
			helpers.assert_contains(text, "[field_check.all.separate_header]\n➖ [menu.debug.field_check_key_accounting] — key_accounting, dropped_letters")
			helpers.assert_true(not text:find("[field_check.verdict_pass]", 1, true), "a check's own verdict line is its mark")
		end)
	end)
end
