--- _shared/lua/perf_budget.lua

--- ==============================================================================
--- MODULE: Performance Budget Report (Lua drivers)
--- DESCRIPTION:
--- The one warning a driver writes when a measured operation (a boot, a
--- reload, a menu rebuild, an AI request, a prediction display) took longer
--- than its budget of the [budgets] section of
--- _shared/modules/timings/constants.toml. The Windows driver writes the same
--- line from infra/perf_budget.ahk; tools/dev/field-log-analyse.py judges the
--- measures against the same keys.
---
--- FEATURES & RATIONALE:
--- 1. One wording for every driver and measure, so a log search or the field
---    log analyser finds every overrun with one pattern.
--- 2. The caller reads the budget at the call site (Timings.ms("budgets", key)),
---    so the timings liveness gate sees which driver reads which budget, and this
---    module holds no copy of a number.
--- 3. Names only: the measure is a closed code, never typed text, a path or a
---    model answer; a name outside the grammar raises.
--- 4. PURE Lua: the caller passes its logger.
--- 5. judge() never takes the measured path down: a budget that cannot be read
---    (a registry without the key, a test stub) is logged as an error and the
---    operation goes on; a wrong measure name still raises, it is a defect.
--- ==============================================================================

local M = {}

--- The warning every driver writes for one overrun.
M.TEMPLATE = "Over budget: %s took %d ms (budget %d ms)."

--- Writes the overrun warning when a measure exceeds its budget.
--- @param warn function The caller's logger warn function, called as warn(log, template, ...).
--- @param log string The caller's logger module tag.
--- @param what string The measure, a closed code such as "boot" or "llm.remote:openai".
--- @param elapsed_ms number What the operation took.
--- @param budget_ms number Its budget, read from [budgets].
--- @return boolean over True when the warning was written.
function M.report(warn, log, what, elapsed_ms, budget_ms)
	if type(warn) ~= "function" then error("perf_budget.report: warn must be a function", 2) end
	if type(log) ~= "string" or log == "" then error("perf_budget.report: log must be a module tag", 2) end
	if type(what) ~= "string" or not what:match("^[%w_.:%-]+$") then
		error("perf_budget.report: the measure must be a closed code, got " .. tostring(what), 2)
	end
	if type(elapsed_ms) ~= "number" or elapsed_ms ~= elapsed_ms or elapsed_ms < 0 then
		error("perf_budget.report: elapsed_ms must be a nonnegative number", 2)
	end
	if type(budget_ms) ~= "number" or budget_ms <= 0 then
		error("perf_budget.report: budget_ms must be positive", 2)
	end
	if elapsed_ms <= budget_ms then return false end
	warn(log, M.TEMPLATE, what, math.floor(elapsed_ms + 0.5), math.floor(budget_ms))
	return true
end

--- Reads a budget and writes the overrun warning, logging a budget it cannot read.
--- @param logger table The caller's logger (warn and error functions).
--- @param log string The caller's logger module tag.
--- @param what string The measure, a closed code.
--- @param elapsed_ms number What the operation took.
--- @param read_budget function Returns the budget, Timings.ms("budgets", key).
--- @return boolean over True when the warning was written.
function M.judge(logger, log, what, elapsed_ms, read_budget)
	if type(logger) ~= "table" or type(logger.error) ~= "function" then
		error("perf_budget.judge: logger must carry warn and error", 2)
	end
	if type(read_budget) ~= "function" then error("perf_budget.judge: read_budget must be a function", 2) end
	local read, budget_ms = pcall(read_budget)
	if not read then
		logger.error(log, "The %s budget could not be read: %s", tostring(what), tostring(budget_ms))
		return false
	end
	return M.report(logger.warn, log, what, elapsed_ms, budget_ms)
end

return M
