--- tests/unit/modules/keymap/test_game_keys.lua

--- ==============================================================================
--- MODULE: Shared Game Keys
--- DESCRIPTION:
--- Replays the shared « Touches de jeu » vectors against the resolver this
--- driver and macOS share; Windows replays the same vectors.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.layouts.game_keys_contract").register(helpers, require("core.fs.engine.paths").shared)
