--- tests/unit/core/ui/webview/test_error_dialog_core.lua

--- Replays the shared error window core and checks the Linux bridge delegates to it.
local helpers = require("tests.helpers")
local Contract = require("tests.lua.error_dialog_core_contract")
Contract.register(helpers, helpers.driver_root() .. "/../_shared")
Contract.register_host(helpers, "error_dialog/bridge.lua", function()
	-- ui/error_dialog/bridge, selected by a declaration unique to it.
	return assert(helpers.read_driver_unit("local function build_report("))
end)
