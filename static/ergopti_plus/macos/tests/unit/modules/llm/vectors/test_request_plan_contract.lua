--- tests/unit/modules/llm/vectors/test_request_plan_contract.lua

--- ==============================================================================
--- MODULE: Shared Request Plan Contract (macOS)
--- DESCRIPTION:
--- Replays the shared request transcripts of the debounce, the rate floor and the
--- batching through the actual macOS assertion owner, against the option set the
--- macOS engine really runs.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.llm_request_plan_contract")
local Policy = require("modules.llm.request_plan_policy")

Contract.run_debounce(helpers, helpers.shared("tests/corpus/llm/request_plan_debounce_vectors.json"),
	"macos", Policy.OPTIONS)
Contract.run_batching(helpers, helpers.shared("tests/corpus/llm/request_plan_batching_vectors.json"))

return true
