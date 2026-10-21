--- tests/unit/modules/keymap/test_layout_rows_policy.lua
--- Shared layout-rows policy, through the actual Linux assertion owner.
local helpers = require("tests.helpers")
require("test.layout_rows_policy_contract").run(helpers,
	helpers.driver_root() .. "/../_shared/tests/corpus/layouts/layout_rows.json")
return true
