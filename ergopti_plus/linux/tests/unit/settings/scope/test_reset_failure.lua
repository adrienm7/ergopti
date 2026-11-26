--- tests/unit/settings/scope/test_reset_failure.lua

--- ==============================================================================
--- MODULE: Reset Failure Message (Linux)
--- DESCRIPTION:
--- Replays the shared contract: a refused global restore or clear names the
--- typed failure point the Windows reset names, in every locale.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.settings.reset_failure_contract")(helpers, require("core.text.engine.json"), helpers.driver_root() .. "/../_shared")
