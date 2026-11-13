-- tests/unit/menu/ui/builder/test_quit_admission.lua

--- ==============================================================================
--- MODULE: Quit Admission (macOS)
--- DESCRIPTION:
--- Replays the shared contract for the decision that refuses the menu's Quit.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.core_lifecycle.quit_admission_contract")(helpers)
