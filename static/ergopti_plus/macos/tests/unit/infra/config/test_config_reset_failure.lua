--- tests/unit/infra/config/test_config_reset_failure.lua

--- ==============================================================================
--- MODULE: Reset Failure Message (macOS)
--- DESCRIPTION:
--- Replays the shared contract: a refused global restore or clear names the
--- typed failure point the Windows reset names, in every locale.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_reset_failure_contract")(helpers, require("json"), helpers.shared(""))
