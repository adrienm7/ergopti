--- tests/unit/modules/shortcuts/test_auto_click_contract.lua

--- ==============================================================================
--- MODULE: Auto-Click Contract Tests (Linux)
--- DESCRIPTION:
--- Registers the shared anti-sleep auto-clicker contract: the matcher and the
--- click policy replay their corpora on LuaJIT, as macOS does on Lua 5.4.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.auto_click_contract").register(helpers, {
	driver = "linux",
	shared = function(relative) return require("core.fs.engine.paths").shared(relative) end,
})
