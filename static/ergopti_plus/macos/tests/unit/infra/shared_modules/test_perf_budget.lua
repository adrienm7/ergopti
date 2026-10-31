--- tests/unit/infra/shared_modules/test_perf_budget.lua

--- ==============================================================================
--- MODULE: perf_budget (shared)
--- DESCRIPTION:
--- The overrun warning every driver writes for a measure over its [budgets]
--- value: one line within budget is silent, one over it is written once with
--- the rounded duration, and a measure name outside the closed grammar or a
--- missing budget raises instead of writing typed text or a silent pass; judge
--- logs a budget it cannot read as an error and never raises for it.
--- ==============================================================================

local helpers = require("tests.helpers")
local PerfBudget = require("perf_budget")

--- A logger warn function that records its calls.
local function recorder()
	local calls = {}
	return calls, function(log, template, ...)
		calls[#calls + 1] = { log = log, text = string.format(template, ...) }
	end
end

helpers.describe("perf_budget: the overrun warning", function()
	helpers.it("stays silent within the budget, budget included", function()
		local calls, warn = recorder()
		helpers.assert_eq(PerfBudget.report(warn, "menu", "menu.rebuild", 250, 250), false)
		helpers.assert_eq(PerfBudget.report(warn, "menu", "menu.rebuild", 12.4, 250), false)
		helpers.assert_eq(#calls, 0)
	end)

	helpers.it("writes one warning over the budget, duration rounded", function()
		local calls, warn = recorder()
		helpers.assert_eq(PerfBudget.report(warn, "BootProfile", "boot", 2900.6, 2500), true)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].log, "BootProfile")
		helpers.assert_eq(calls[1].text, "Over budget: boot took 2901 ms (budget 2500 ms).")
	end)

	helpers.it("refuses a measure name outside the closed grammar", function()
		local _, warn = recorder()
		for _, name in ipairs({ "typed text", "", "a/b", 3 }) do
			helpers.assert_eq(pcall(PerfBudget.report, warn, "menu", name, 300, 250), false, tostring(name))
		end
	end)

	helpers.it("refuses a missing or nonpositive budget and a bad duration", function()
		local _, warn = recorder()
		helpers.assert_eq(pcall(PerfBudget.report, warn, "menu", "menu.rebuild", 300, nil), false)
		helpers.assert_eq(pcall(PerfBudget.report, warn, "menu", "menu.rebuild", 300, 0), false)
		helpers.assert_eq(pcall(PerfBudget.report, warn, "menu", "menu.rebuild", -1, 250), false)
		helpers.assert_eq(pcall(PerfBudget.report, warn, "menu", "menu.rebuild", 0 / 0, 250), false)
		helpers.assert_eq(pcall(PerfBudget.report, nil, "menu", "menu.rebuild", 300, 250), false)
	end)

	helpers.it("judge reads the budget and logs one it cannot read without raising", function()
		local warned, warn = recorder()
		local errors, error_fn = recorder()
		local logger = { warn = warn, error = error_fn }
		helpers.assert_eq(PerfBudget.judge(logger, "LLM", "llm.remote", 3400, function() return 3000 end), true)
		helpers.assert_eq(warned[1].text, "Over budget: llm.remote took 3400 ms (budget 3000 ms).")
		helpers.assert_eq(PerfBudget.judge(logger, "LLM", "llm.remote", 3400,
			function() error("missing [budgets] key") end), false)
		helpers.assert_eq(#errors, 1)
		helpers.assert_contains(errors[1].text, "llm.remote budget could not be read")
		local ok, err = pcall(PerfBudget.judge, logger, "LLM", "typed text", 3400, function() return 3000 end)
		helpers.assert_eq(ok, false, "a wrong measure name is a defect, not a missing budget")
		helpers.assert_contains(tostring(err), "the measure must be a closed code, got typed text")
	end)
end)
