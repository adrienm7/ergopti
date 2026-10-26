--- tests/unit/modules/llm/vectors/test_request_plan_contract.lua

--- ==============================================================================
--- MODULE: Shared Request Plan Contract (macOS)
--- DESCRIPTION:
--- Replays the shared request transcripts of the debounce, the rate floor, the
--- batching, the token budget, the info bar and the live prompt through the actual macOS assertion owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.llm_request_plan_contract")

Contract.run_debounce(helpers, helpers.shared("tests/corpus/llm/request_plan_debounce_vectors.json"), "macos")
Contract.run_batching(helpers, helpers.shared("tests/corpus/llm/request_plan_batching_vectors.json"))
Contract.run_token_budget(helpers, helpers.shared("tests/corpus/llm/request_plan_token_budget_vectors.json"))

return true
