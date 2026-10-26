--- tests/unit/modules/llm/prediction/test_request_plan_contract.lua

--- ==============================================================================
--- MODULE: Shared Request Plan Contract (Linux)
--- DESCRIPTION:
--- Replays the shared request transcripts of the debounce, the rate floor and the
--- batching through the actual Linux assertion owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.llm_request_plan_contract")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/"

Contract.run_debounce(helpers, CORPUS .. "request_plan_debounce_vectors.json", "linux")
Contract.run_batching(helpers, CORPUS .. "request_plan_batching_vectors.json")

return true
