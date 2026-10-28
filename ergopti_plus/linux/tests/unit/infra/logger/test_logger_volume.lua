--- tests/unit/infra/logger/test_logger_volume.lua

--- ==============================================================================
--- MODULE: Logger Volume Counters (Linux)
--- DESCRIPTION:
--- Replays the shared log-volume contract on the shared core this driver runs.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.logger_volume_contract")(helpers, helpers.driver_root() .. "/../_shared")
