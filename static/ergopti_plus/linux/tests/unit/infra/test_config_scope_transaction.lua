--- tests/unit/infra/test_config_scope_transaction.lua

require("test.config_scope_transaction_contract")(require("tests.helpers"))
require("test.config_scope_plan_contract")(require("tests.helpers"))
require("test.config_scope_file_contract")(require("tests.helpers"))

require("test.config_scope_script_runtime_contract")(require("tests.helpers"), "linux")
require("test.config_scope_script_field_contract")(require("tests.helpers"), "linux")

require("test.config_scope_script_contract")(require("tests.helpers"), "linux")
