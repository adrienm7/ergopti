-- tests/unit/ui/menu/test_quit_admission.lua

--- ==============================================================================
--- MODULE: Quit Admission (macOS)
--- DESCRIPTION:
--- Replays the shared contract for the decision that refuses the menu's Quit.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.quit_admission_contract")(helpers)
