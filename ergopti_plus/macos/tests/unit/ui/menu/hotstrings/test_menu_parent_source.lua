--- tests/unit/ui/menu/hotstrings/test_menu_parent_source.lua

--- ==============================================================================
--- MODULE: Shared Menu Parent Source
--- DESCRIPTION:
--- Replays the shared parent source admission contract against this driver,
--- which owns the same one body as the other driver.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.menu_parent_source_contract").register(helpers)
