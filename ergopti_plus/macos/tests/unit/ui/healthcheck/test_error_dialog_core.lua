--- tests/unit/ui/healthcheck/test_error_dialog_core.lua

--- Replays the shared error window core and checks the macOS host delegates to it.
local helpers = require("tests.helpers")
local Contract = require("test.error_dialog_core_contract")
Contract.register(helpers, helpers.shared(""))
-- The host is the one production unit requiring the core, found by that require.
Contract.register_host(helpers, "the macOS error window", function()
	return assert(helpers.read_driver_unit('require("error_dialog.core")'))
end)
