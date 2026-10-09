--- tests/unit/infra/test_config_scope_transaction.lua

require("test.config_scope_transaction_contract")(require("tests.helpers"))
require("test.config_scope_plan_contract")(require("tests.helpers"))
require("test.config_scope_file_contract")(require("tests.helpers"))

require("test.config_scope_script_runtime_contract")(require("tests.helpers"), "macos")
require("test.config_scope_script_field_contract")(require("tests.helpers"), "macos")

require("test.config_scope_script_contract")(require("tests.helpers"), "macos")

local helpers = require("tests.helpers")
helpers.describe("script native alias descriptors", function()
	helpers.it("script-native-aliases exposes detached descriptors of the actual participant", function()
		local Scope = require("infra.script_scope")
		local first, second = Scope.native_aliases(), Scope.native_aliases()
		helpers.assert_true(type(first) == "table" and next(first) ~= nil)
		helpers.assert_true(not rawequal(first, second))
		local count = 0
		for path, descriptor in pairs(first) do
			count = count + 1
			helpers.assert_true(type(path) == "string" and type(descriptor.alias) == "string" and descriptor.alias ~= "")
			helpers.assert_true(type(descriptor.native) == "table" and type(descriptor.native.scope_capture) == "function")
			helpers.assert_true(not rawequal(descriptor, second[path]))
			helpers.assert_eq(descriptor.alias, second[path].alias); helpers.assert_true(rawequal(descriptor.native, second[path].native))
			descriptor.alias, descriptor.native = "detached adversary", {}
		end
		local third, third_count = Scope.native_aliases(), 0
		for path, descriptor in pairs(third) do
			third_count = third_count + 1
			helpers.assert_eq(descriptor.alias, second[path].alias); helpers.assert_true(rawequal(descriptor.native, second[path].native))
		end
		helpers.assert_eq(third_count, count)
	end)
end)
