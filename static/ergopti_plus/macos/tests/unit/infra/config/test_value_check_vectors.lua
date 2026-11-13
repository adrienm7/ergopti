--- tests/unit/infra/config/test_value_check_vectors.lua

--- ==============================================================================
--- MODULE: macOS User Value Check Vectors
--- DESCRIPTION:
--- Replays the shared value check vectors and schema shape checks
--- (_shared/tests/lua/value_check_contract.lua) on the Hammerspoon runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.value_check_contract").register(helpers, helpers.shared)
