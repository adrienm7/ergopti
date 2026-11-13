--- tests/unit/metrics/engine/storage/test_queries_contract.lua

--- ==============================================================================
--- MODULE: Keystats Named-Query Contract (macOS)
--- DESCRIPTION:
--- Runs the shared contract of the generated named-query renderer the macOS
--- reader renders its SQL through. The Linux suite runs the same contract.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.metrics.queries_contract").register(helpers,
	helpers.shared("tests/corpus/keystats/write_query_vectors.json"))
