--- tests/unit/hotstrings/engine/matcher/test_choice_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Choice Catalogue Judgement (macOS)
--- DESCRIPTION:
--- Replays the shared judgement of an explicit category or section choice, the
--- rule the preferences owner uses to report retired entries.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.hotstrings.choice_catalogue_contract").run(helpers, require("hotstrings.engine.choice_catalogue"))
