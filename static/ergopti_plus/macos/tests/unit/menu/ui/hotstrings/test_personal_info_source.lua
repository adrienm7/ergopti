--- tests/unit/menu/ui/hotstrings/test_personal_info_source.lua

--- ==============================================================================
--- MODULE: Shared Personal Information Source
--- DESCRIPTION:
--- Replays the shared personal information source admission contract against this driver,
--- which owns the same one body as the other driver.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.menu.personal_info_source_contract").register(helpers)
