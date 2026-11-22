--- tests/unit/ai/engine/prediction/test_display_budget.lua

--- ==============================================================================
--- MODULE: Prediction First Display Budget Tests (Linux)
--- DESCRIPTION:
--- macOS judges a prediction's first display against [budgets]
--- prediction_display_ms; the Linux engine judged nothing, so a slow first
--- display never reached the log or tools/dev/field-log-analyse.py
--- (linux-display-budget, timing parity campaign TIM-04). The clock and the
--- budget are ports; the lines are the delivered log lines; the engine's two
--- call sites are read from its source.
--- ==============================================================================

local helpers = require("tests.support.logger_fixture").helpers({
	"ai.engine.prediction.display_budget", "core.logger.engine.perf_budget",
})

--- Loads a fresh module with the real logger capturing its lines.
--- @return table DisplayBudget, table lines
local function fixture()
	package.loaded["core.logger.engine"] = nil
	package.loaded["core.logger.engine.shim"] = nil
	package.loaded["core.logger.engine.perf_budget"] = nil
	package.loaded["ai.engine.prediction.display_budget"] = nil
	local logger = require("core.logger.engine")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(10)
	return require("ai.engine.prediction.display_budget"), lines
end

--- The delivered lines that contain a text.
local function matching(lines, text)
	local found = {}
	for _, line in ipairs(lines) do if line:find(text, 1, true) then found[#found + 1] = line end end
	return found
end

helpers.describe("Linux prediction first display budget (linux-display-budget)", function()
	helpers.it("(linux-display-budget) a slow first display writes the shared overrun line once per chain", function()
		local DisplayBudget, lines = fixture()
		local clock = { now = 500 }
		local chain = DisplayBudget.start({ now_ms = function() return clock.now end, budget_ms = function() return 2000 end })
		clock.now = 500 + 2600
		helpers.assert_eq(chain.shown(), 2600)
		clock.now = 500 + 4000
		helpers.assert_eq(chain.shown(), nil)
		helpers.assert_eq(#matching(lines, "Over budget: prediction.display took 2600 ms (budget 2000 ms)."), 1)
		helpers.assert_eq(#matching(lines, "Over budget"), 1)
	end)

	helpers.it("(linux-display-budget) a first display within its budget writes no overrun", function()
		local DisplayBudget, lines = fixture()
		local clock = { now = 0 }
		local chain = DisplayBudget.start({ now_ms = function() return clock.now end, budget_ms = function() return 2000 end })
		clock.now = 1200
		helpers.assert_eq(chain.shown(), 1200)
		helpers.assert_eq(#matching(lines, "Over budget"), 0)
	end)

	helpers.it("(linux-display-budget) the production budget is the registry's prediction_display_ms", function()
		local DisplayBudget = fixture()
		helpers.assert_eq(DisplayBudget.production_ports().budget_ms(),
			require("core.timing.engine.timings").ms("budgets", "prediction_display_ms"))
	end)

	helpers.it("(linux-display-budget) the engine starts a chain per request and judges its first drawn candidates", function()
		local root = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/unit/")
		local file = assert(io.open(root .. "/ai/engine/prediction/engine.lua", "r"))
		local source = file:read("*a")
		file:close()
		local sending = source:find("Sending %sprediction request", 1, true)
		local started = source:find("local display_chain = DisplayBudget.start(DisplayBudget.production_ports())", 1, true)
		local shown = source:find("show_candidates(visible, meta) and #visible > 0 and _overlay then display_chain.shown() end",
			1, true)
		helpers.assert_true(sending ~= nil and started ~= nil and started > sending,
			"the chain starts once the request is sent")
		helpers.assert_true(shown ~= nil and shown > started, "the first drawn candidates are judged")
	end)
end)
