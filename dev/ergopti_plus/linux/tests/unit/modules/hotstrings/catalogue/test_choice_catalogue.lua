--- tests/unit/modules/hotstrings/catalogue/test_choice_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Choice Catalogue Judgement (Linux)
--- DESCRIPTION:
--- Replays the shared judgement of an explicit category or section choice, the
--- rule the canonical choice owner uses to report retired entries.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.hotstring_choice_catalogue_contract").run(helpers, require("hotstrings.choice_catalogue"))
