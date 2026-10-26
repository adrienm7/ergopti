--- tests/unit/modules/llm/prediction/test_request_plan_contract.lua

--- ==============================================================================
--- MODULE: Shared Request Plan Contract (Linux)
--- DESCRIPTION:
--- Replays the shared request transcripts of the debounce, the rate floor, the
--- batching, the token budget, the info bar and the live prompt through the actual Linux assertion owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.llm_request_plan_contract")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/"

Contract.run_debounce(helpers, CORPUS .. "request_plan_debounce_vectors.json", "linux")
Contract.run_batching(helpers, CORPUS .. "request_plan_batching_vectors.json")
Contract.run_token_budget(helpers, CORPUS .. "request_plan_token_budget_vectors.json")
Contract.run_info_bar(helpers, CORPUS .. "request_plan_info_bar_vectors.json")
Contract.run_live(helpers, CORPUS .. "request_plan_live_vectors.json")
Contract.run_ports(helpers, {
	HttpClient = require("adapters.http_client"),
	TimerScheduler = require("adapters.timer_scheduler"),
	TooltipRenderer = require("adapters.graphics_renderer"),
})

return true
