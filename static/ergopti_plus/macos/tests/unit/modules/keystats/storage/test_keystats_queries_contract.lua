--- tests/unit/modules/keystats/storage/test_keystats_queries_contract.lua

--- ==============================================================================
--- MODULE: Keystats Named-Query Contract (macOS)
--- DESCRIPTION:
--- Runs the shared contract of the generated named-query renderer the macOS
--- reader renders its SQL through. The Linux suite runs the same contract.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.keystats_queries_contract").register(helpers)
