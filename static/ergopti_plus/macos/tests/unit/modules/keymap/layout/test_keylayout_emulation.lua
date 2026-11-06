--- tests/unit/modules/keymap/layout/test_keylayout_emulation.lua

--- ==============================================================================
--- MODULE: Shared Keylayout Emulation
--- DESCRIPTION:
--- Replays the cross-OS keystroke oracle against the emulation engine this
--- driver and Linux share; Windows replays the same keystroke vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.keylayout_emulation_contract").register(helpers, helpers.shared)
