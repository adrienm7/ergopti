--- tests/unit/infra/config/test_config_save_failure.lua

--- ==============================================================================
--- MODULE: Configuration Save Failure Notice (macOS)
--- DESCRIPTION:
--- Replays the shared contract: a refused change the writer already named as a
--- case twin shows no second, generic notice from the menu.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.settings.save_failure_contract")(helpers, helpers.driver_root())
