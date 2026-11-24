--- _shared/tests/lua/diagnostics/field_report_contract.lua

--- Exercises the report of Débogage's « Lancer le field report »
--- (_shared/diagnostics/engine/field_check/field_report.lua) under a driver's
--- suite: the field points come from the coverage file; the counts, each
--- step's verdict and its field points, the steps not run with their reason,
--- the rows to run separately and the saved folder are all in the text; a
--- step a Tests row runs alone reads as that row's sentences, a developer step
--- as its closed codes; an interrupted run says so; the evidence line follows
--- the field check grammar.
return function(helpers)
	local FieldReport = require("diagnostics.engine.field_check.field_report")
	local Report = require("diagnostics.engine.field_check.report")

	local COVERAGE = { points = {
		{ id = "pac_real", checks = { { step = "field_network" }, { step = "field_network", report = { "x" } } } },
		{ id = "l42_off_company_network", checks = { { step = "field_network" } } },
		{ id = "timed_reload", checks = { { step = "driver_reload" } } },
		{ id = "untestable", checks = {}, not_testable = "needs a person" },
	} }

	local translate = function(key)
		if key == "common.label_value" then return "{1} : {2}" end
		if key == "field_check.all.saved_in" then return "saved {1}" end
		return "[" .. key .. "]"
	end

	local function report_of(check, state)
		local report = Report.new_report(check)
		report.step("probe", state, state == Report.STATE_INFO and 3010 or nil)
		return report.result()
	end

	local function summary(interrupted, results)
		return FieldReport.summary({
			results = results or {
				{ step = "field_network", verdict = "pass", codes = {}, report = report_of("network", Report.STATE_PASS) },
				{ step = "field_boot_cost", verdict = "fail", codes = { "fail_probe" }, report = report_of("boot_cost", Report.STATE_INFO) },
				{ step = "field_slow", verdict = "timeout", codes = { "deadline_10s" }, report = {} },
				{ step = "config_guard", verdict = "pass", codes = {} },
			},
			not_run = { { step = "driver_reload", reason = "needs_collector" } },
			separate = { { row = "field_check_key_accounting" } },
			coverage = COVERAGE,
			done = { request_id = "app-20261124T120000Z", interrupted = interrupted },
			dir = "/run/field-run/results/app-20261124T120000Z",
		})
	end

	local function title_of(step)
		return step == "field_network" and "[menu.debug.field_check_network]" or nil
	end

	helpers.describe("field report: the in-app report", function()
		helpers.it("lists each step's field points from the coverage, once each", function()
			local points = FieldReport.points_by_step(COVERAGE)
			helpers.assert_eq(points.field_network, { "pac_real", "l42_off_company_network" })
			helpers.assert_eq(points.driver_reload, { "timed_reload" })
			helpers.assert_eq(FieldReport.points_by_step(nil), {})
		end)

		helpers.it("names the counts, each verdict with its field points, the steps not run and the folder", function()
			local text = FieldReport.format_text(summary(false), translate, title_of)
			helpers.assert_true(text:find("[field_check.all.verdict_fail]", 1, true) == 1, text)
			helpers.assert_contains(text, "✅ 2 · ❌ 1 · ⏱️ 1 · ➖ 1")
			helpers.assert_contains(text, "✅ [menu.debug.field_check_network] — field_network, pac_real, l42_off_company_network\n    ✅ [field_check.step.probe]")
			helpers.assert_contains(text, "❌ field_boot_cost\n    ℹ️ probe : 3010")
			helpers.assert_contains(text, "⏱️ field_slow\n    deadline_10s")
			helpers.assert_contains(text, "[field_check.all.not_run_header]\n➖ driver_reload — timed_reload : [field_check.all.reason.needs_collector]")
			helpers.assert_contains(text, "[field_check.all.separate_header]\n➖ [menu.debug.field_check_key_accounting]")
			helpers.assert_contains(text, "saved /run/field-run/results/app-20261124T120000Z\n[field_check.all.attach]")
			helpers.assert_true(not text:find("[field_check.verdict_pass]", 1, true), "a step's own verdict line is its mark")
		end)

		helpers.it("passes only when every step passed or was skipped, and says when the run was interrupted", function()
			local passing = summary(false, { { step = "field_network", verdict = "pass", codes = {} },
				{ step = "field_lease", verdict = "skip", codes = { "not_granted" } } })
			helpers.assert_true(passing.passed)
			helpers.assert_contains(FieldReport.format_text(passing, translate, title_of), "[field_check.all.verdict_pass]")
			local cut = summary(true, { { step = "field_network", verdict = "pass", codes = {} } })
			helpers.assert_true(not cut.passed)
			helpers.assert_true(FieldReport.format_text(cut, translate, title_of):find("[field_check.all.interrupted]", 1, true) == 1)
		end)

		helpers.it("writes one evidence line in the field check grammar", function()
			helpers.assert_eq(FieldReport.format_log_line(summary(false)),
				"check=field_report verdict=fail request=app-20261124T120000Z pass=2 fail=1 timeout=1 not_run=1 "
				.. "field_network=pass field_boot_cost=fail field_slow=timeout config_guard=pass")
		end)

		helpers.it("refuses a verdict the shared protocol does not declare", function()
			helpers.assert_throws(function()
				FieldReport.format_text(summary(false, { { step = "x", verdict = "partial", codes = {} } }), translate, title_of)
			end)
		end)
	end)
end
