--- tests/unit/ui/webview/test_error_dialog_core.lua

--- Replays the shared error window core and checks the Linux bridge delegates to it.
local helpers = require("tests.helpers")
local Contract = require("test.error_dialog_core_contract")
Contract.register(helpers, helpers.driver_root() .. "/../_shared")
Contract.register_host(helpers, "error_dialog/bridge.lua", function()
	local file = assert(io.open(helpers.driver_root() .. "/ui/error_dialog/bridge.lua", "rb"))
	local source = assert(file:read("*a"))
	assert(file:close())
	return source
end)
