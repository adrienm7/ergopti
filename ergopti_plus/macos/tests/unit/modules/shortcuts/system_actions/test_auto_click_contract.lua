--- tests/unit/modules/shortcuts/system_actions/test_auto_click_contract.lua

--- ==============================================================================
--- MODULE: Auto-Click Contract Tests (macOS)
--- DESCRIPTION:
--- Registers the shared anti-sleep auto-clicker contract: the matcher and the
--- click policy replay their corpora on Lua 5.4, as Linux does on LuaJIT.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.auto_click_contract").register(helpers, { driver = "macos", shared = helpers.shared })
