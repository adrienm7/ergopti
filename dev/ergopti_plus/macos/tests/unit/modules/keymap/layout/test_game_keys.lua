--- tests/unit/modules/keymap/layout/test_game_keys.lua

--- ==============================================================================
--- MODULE: Shared Game Keys
--- DESCRIPTION:
--- Replays the shared « Touches de jeu » vectors against the resolver this
--- driver and Linux share; Windows replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.layouts.game_keys_contract").register(helpers, helpers.shared)
