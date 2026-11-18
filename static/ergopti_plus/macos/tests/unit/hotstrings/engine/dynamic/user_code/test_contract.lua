--- tests/unit/hotstrings/engine/dynamic/user_code/test_contract.lua

--- Registers independent programmable-rule and exact-source contracts.
local helpers = require("tests.helpers")
require("tests.lua.hotstrings.user_hotstrings_contract").run(helpers, require("hotstrings.engine.dynamic.user_code_core"))
require("tests.lua.hotstrings.user_hotstring_source_contract").run(helpers, require("hotstrings.engine.dynamic.user_source"))

return true
