--- tests/unit/infra/config/test_value_check_vectors.lua

--- ==============================================================================
--- MODULE: Linux User Value Check Vectors
--- DESCRIPTION:
--- Replays the shared value check vectors and schema shape checks
--- (_shared/tests/lua/value_check_contract.lua) on the Linux runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.value_check_contract").register(helpers, require("core.fs.engine.paths").shared)
