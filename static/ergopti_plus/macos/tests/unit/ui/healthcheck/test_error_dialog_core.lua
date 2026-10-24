--- tests/unit/ui/healthcheck/test_error_dialog_core.lua

--- Replays the shared error window core and checks the macOS host delegates to it.
local helpers = require("tests.helpers")
local Contract = require("test.error_dialog_core_contract")
Contract.register(helpers, helpers.shared(""))
Contract.register_host(helpers, helpers.driver_root() .. "/ui/error_dialog/init.lua")
