--- ai/engine/prediction/display_budget.lua

--- ==============================================================================
--- MODULE: Prediction First Display Budget (Linux)
--- DESCRIPTION:
--- Judges one prediction's first display, from the request it sends to the
--- first candidates the overlay draws, against [budgets] prediction_display_ms,
--- as the macOS and Windows tooltips judge their TTFT.
---
--- FEATURES & RATIONALE:
--- 1. One chain, one judgement: a later partial or final render of the same
---    request is the same display, not a new one.
--- 2. The shared overrun line (_shared/core/logger/engine/perf_budget.lua), so
---    tools/dev/field-log-analyse.py reads the three drivers with one pattern.
--- 3. The clock and the budget reader are ports, so a test drives both.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local PerfBudget = require("core.logger.engine.perf_budget")

local LOG = "ai.engine.prediction.display_budget"

--- Starts one prediction chain.
--- @param ports table { now_ms = function() -> number, budget_ms = function() -> number }
--- @return table chain { shown = function() -> number|nil }: the TTFT the first call judged, nil after
function M.start(ports)
	assert(type(ports) == "table" and type(ports.now_ms) == "function" and type(ports.budget_ms) == "function",
		"a display budget chain needs a clock and a budget reader")
	local started_ms = ports.now_ms()
	local judged = false
	local chain = {}

	--- Records the chain's first display; later calls do nothing.
	--- @return number|nil ttft_ms
	function chain.shown()
		if judged then return nil end
		judged = true
		local ttft_ms = ports.now_ms() - started_ms
		Logger.debug(LOG, "First prediction display after %d ms.", ttft_ms)
		PerfBudget.judge(Logger, LOG, "prediction.display", ttft_ms, ports.budget_ms)
		return ttft_ms
	end

	return chain
end

--- The production ports: the daemon's monotonic clock and the shared registry.
--- @return table ports
function M.production_ports()
	return {
		now_ms = require("core.logger.engine.monotonic").now_ms,
		budget_ms = function() return require("core.timing.engine.timings").ms("budgets", "prediction_display_ms") end,
	}
end

return M
