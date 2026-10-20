--- tests/unit/ui/menu/keyboard_layout/test_layout_rows_policy.lua

--- ==============================================================================
--- MODULE: Layout Rows Policy Tests
--- DESCRIPTION:
--- Replays the shared layout-rows contract through the macOS test owner: macOS
--- emulates no layout, so its menu greys the row switches it declares.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.layout_rows_policy_contract").run(helpers,
	helpers.shared("tests/corpus/layouts/layout_rows.json"))

return true
