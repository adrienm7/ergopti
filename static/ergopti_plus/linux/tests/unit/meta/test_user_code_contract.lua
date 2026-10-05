--- tests/unit/meta/test_user_code_contract.lua

--- Registers independent programmable-rule and exact-source contracts.
local helpers = require("tests.helpers")
require("test.user_hotstrings_contract").run(helpers, require("dynamic_hotstrings.user_code"))
require("test.user_hotstring_source_contract").run(helpers, require("dynamic_hotstrings.user_source"))

return true
