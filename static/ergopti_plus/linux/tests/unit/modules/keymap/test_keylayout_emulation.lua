--- tests/unit/modules/keymap/test_keylayout_emulation.lua

--- ==============================================================================
--- MODULE: Shared Keylayout Emulation
--- DESCRIPTION:
--- Replays the cross-OS keystroke oracle against the emulation engine this
--- driver and macOS share; Windows replays the same keystroke vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.layouts.keylayout_emulation_contract").register(helpers, require("infra.paths").shared)
