--- tests/unit/modules/keymap/layout/test_source_emulation.lua

--- ==============================================================================
--- MODULE: Shared Layout Source Emulation
--- DESCRIPTION:
--- Replays the shared typing vectors of the layout source emulation (custom
--- modifiers, shortcuts, tap-holds) against the engine this driver and Linux
--- share; the web engine replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.source_emulation_contract").register(helpers, helpers.shared)
