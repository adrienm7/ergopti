--- tests/unit/keyboard/test_tap_copy_check.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy Check
--- DESCRIPTION:
--- Replays the shared copy check against a fake clipboard counter and clock.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.keyboard.tap_hold_copy_check_contract")(helpers, require("tap_hold.engine.copy_check"))
