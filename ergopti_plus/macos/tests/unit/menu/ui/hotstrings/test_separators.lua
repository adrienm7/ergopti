--- tests/unit/menu/ui/hotstrings/test_separators.lua

--- ==============================================================================
--- MODULE: Shared Menu Separator Rules
--- DESCRIPTION:
--- Replays the shared separator vectors against this driver, which renders its
--- menus through the same one rule as the other driver.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.menu.separators_contract").register(helpers,
	helpers.shared("tests/corpus/menus/separator_normalization_vectors.json"))
