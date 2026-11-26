--- tests/unit/diagnostics/ui/healthcheck/test_error_dialog_core.lua

--- Replays the shared error window core and checks the macOS host delegates to it.
local helpers = require("tests.helpers")
local Contract = require("tests.lua.error_dialog_core_contract")
Contract.register(helpers, helpers.shared(""))
-- The host is the one production unit requiring the core, found by that require.
Contract.register_host(helpers, "the macOS error window", function()
	return assert(helpers.read_driver_unit('require("core.ui.engine.error_dialog_core")'))
end)
