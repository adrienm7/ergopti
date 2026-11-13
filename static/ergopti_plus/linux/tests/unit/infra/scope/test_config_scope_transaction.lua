--- tests/unit/infra/scope/test_config_scope_transaction.lua

require("tests.lua.settings.scope_transaction_contract")(require("tests.helpers"))
require("tests.lua.settings.scope_plan_contract")(require("tests.helpers"))
require("tests.lua.settings.scope_file_contract")(require("tests.helpers"))

require("tests.lua.settings.scope_script_runtime_contract")(require("tests.helpers"), "linux")
require("tests.lua.settings.scope_script_field_contract")(require("tests.helpers"), "linux")

require("tests.lua.settings.scope_script_contract")(require("tests.helpers"), "linux")
