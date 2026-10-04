--- tests/unit/keymap/test_number_row_policy.lua
--- Shared typed number-row policy, through the actual Linux assertion owner.
local helpers = require("tests.helpers")
require("test.number_row_policy_contract").run(helpers,
	helpers.driver_root() .. "/../_shared/tests/corpus/layouts/number_row_policy.json")
return true
