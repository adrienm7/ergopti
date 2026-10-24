--- tests/unit/infra/config/test_config_keys.lua

--- ==============================================================================
--- MODULE: Config-Key Constants Tests
--- DESCRIPTION:
--- The generated shared module must answer the schema's own spelling for every
--- constant and raise on a misspelt one: a string key that does not exist reads
--- as nil and lets the default apply silently, which is the failure the
--- constants exist to remove.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("config_keys: generated constants", function()
	helpers.it("answers the dotted key, the leaf and the command id", function()
		local ConfigKeys = require("config_keys")
		helpers.assert_eq(ConfigKeys.KEY.METRICS_PRIVATE_FILTER_ENABLED, "metrics.private_filter_enabled")
		helpers.assert_eq(ConfigKeys.LEAF.PRIVATE_FILTER_ENABLED, "private_filter_enabled")
		helpers.assert_eq(ConfigKeys.COMMAND.FILTER_PRIVATE, "filter_private")
	end)

	helpers.it("raises on an unknown constant instead of answering nil", function()
		local ConfigKeys = require("config_keys")
		helpers.assert_throws(function() return ConfigKeys.KEY.METRICS_PRIVATE_FILTER_ENABLD end)
		helpers.assert_throws(function() return ConfigKeys.LEAF.NOT_A_LEAF end)
		helpers.assert_throws(function() return ConfigKeys.COMMAND.NOT_A_COMMAND end)
	end)

	helpers.it("refuses a write so no caller can redefine a key", function()
		local ConfigKeys = require("config_keys")
		helpers.assert_throws(function() ConfigKeys.KEY.EXTRA = "extra" end)
	end)
end)
