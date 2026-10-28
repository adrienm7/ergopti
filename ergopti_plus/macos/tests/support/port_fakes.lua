--- tests/support/port_fakes.lua

--- ==============================================================================
--- MODULE: Request Plan Port Fakes (macOS)
--- DESCRIPTION:
--- Complete doubles of the ports the prediction engine checks at init
--- (llm.request_plan.ports): a TimerScheduler with after/cancel, an HttpClient
--- with post/cancel and a prediction tooltip with show_predictions/hide/
--- is_visible. A test that only needs the engine to initialise starts from
--- these instead of a partial stub, and overrides what it observes.
--- ==============================================================================

local M = {}

--- @param overrides table|nil Members replacing the defaults.
--- @return table scheduler after (an unarmed handle), cancel, every, cancelAll
function M.timer_scheduler(overrides)
	local fake = {
		after = function() return { fired = false, committed = true }, true end,
		every = function() return { fired = false, committed = true }, true end,
		cancel = function() return true end,
		cancelAll = function() return true end,
	}
	for key, value in pairs(overrides or {}) do fake[key] = value end
	return fake
end

--- @param overrides table|nil
--- @return table client post (refuses nothing, answers nothing), cancel
function M.http_client(overrides)
	local fake = {
		post = function() return true end,
		cancel = function() return true end,
	}
	for key, value in pairs(overrides or {}) do fake[key] = value end
	return fake
end

--- Adds the members a prediction tooltip must offer to a stub.
--- @param tooltip table|nil The test's own stub (modified and returned).
--- @return table tooltip
function M.complete_tooltip(tooltip)
	tooltip = tooltip or {}
	if tooltip.show_predictions == nil then tooltip.show_predictions = function() return true end end
	if tooltip.hide == nil then tooltip.hide = function() return true end end
	if tooltip.is_visible == nil then tooltip.is_visible = function() return false end end
	return tooltip
end

return M
