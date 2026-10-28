--- tests/unit/ui/menu/structure/test_menu_separators.lua

--- ==============================================================================
--- MODULE: Shared Menu Separator Rules
--- DESCRIPTION:
--- Replays the shared separator vectors against this driver, which renders its
--- menus through the same one rule as the other driver.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.menu_separators_contract").register(helpers,
	require("infra.paths").shared("tests/corpus/menus/separator_normalization_vectors.json"))
