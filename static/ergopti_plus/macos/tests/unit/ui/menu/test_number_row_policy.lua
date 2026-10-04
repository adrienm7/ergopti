--- tests/unit/ui/menu/test_number_row_policy.lua

--- ==============================================================================
--- MODULE: Number Row Policy Tests
--- DESCRIPTION:
--- Replays the shared source/capability contract through the macOS test owner.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.number_row_policy_contract").run(helpers,
	helpers.shared("tests/corpus/layouts/number_row_policy.json"))

return true
