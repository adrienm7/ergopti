--- tests/unit/modules/keymap/test_repeat_neutral_config.lua

local helpers = require("tests.helpers")
local codec = require("toml_codec")

helpers.describe("neutral repeat configuration", function()
	helpers.it("requires explicit repeat intent and saves it through the canonical sparse preferences", function()
		helpers.with_fresh_modules({ "modules.keymap.registry_index", "infra.preferences", "adapters.file_system" }, function()
			local source, writes = "", 0
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return source, "ok" end,
				write = function() error("unguarded write") end,
				write_if_unchanged = function(_, content, expected)
					helpers.assert_eq(expected.content, source)
					source, writes = content, writes + 1
					return true
				end,
			}
			local registry = helpers.load_with_stubs("modules.keymap.registry_index")
			local prefs = helpers.load_with_stubs("infra.preferences")
			helpers.assert_eq(registry.is_repeat_feature_enabled(), false)
			helpers.assert_eq(registry.set_repeat_feature_enabled(true), true)
			helpers.assert_eq(prefs.save("/repeat/config.toml", {}, {}, { keymap = registry }), true)
			helpers.assert_eq(codec.decode(source).hotstrings.repeat_key_enabled, true)
			helpers.assert_eq(registry.set_repeat_feature_enabled(false), true)
			helpers.assert_eq(prefs.save("/repeat/config.toml", {}, {}, { keymap = registry }), true)
			helpers.assert_eq(codec.decode(source).hotstrings.repeat_key_enabled, nil)
			helpers.assert_eq(writes, 2)
		end)
	end)
end)
