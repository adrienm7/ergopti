--- tests/unit/modules/keystats/storage/test_keystats_queries_contract.lua

--- ==============================================================================
--- MODULE: Keystats Named-Query Contract (Linux)
--- DESCRIPTION:
--- Runs the shared contract of the generated named-query renderer the Linux
--- reader renders its SQL through. The macOS suite runs the same contract.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.keystats_queries_contract").register(helpers)
