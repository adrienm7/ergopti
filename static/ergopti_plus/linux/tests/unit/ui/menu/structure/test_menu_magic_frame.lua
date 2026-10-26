--- tests/unit/ui/menu/structure/test_menu_magic_frame.lua

--- ==============================================================================
--- MODULE: Shared Magic Trigger Frame
--- DESCRIPTION:
--- Replays the shared frame snapshot contract against this driver, which owns
--- the same one body as the other driver.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.menu_magic_frame_contract").register(helpers)
