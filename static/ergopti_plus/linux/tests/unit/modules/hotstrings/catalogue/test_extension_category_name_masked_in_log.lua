--- tests/unit/modules/hotstrings/catalogue/test_extension_category_name_masked_in_log.lua

--- ==============================================================================
--- MODULE: Extension Category Names Stay Out of the Log (Linux)
--- DESCRIPTION:
--- When a user's file overrides a category a file extension binds, the config
--- manager logs that it did (item 139). The category is named by the user's file,
--- so the line carries the shared placeholder, never the name in clear text.
--- Fails if the category name appears in a captured log line.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture")
local helpers, user_folder, write, one_entry_pack, load_with_user_folder =
	Fixture.helpers, Fixture.user_folder, Fixture.write, Fixture.one_entry_pack, Fixture.load_with_user_folder

helpers.describe("Config manager: a category name is masked in the log", function()
	helpers.it("(category-name-log-mask) never prints the overridden category's name", function()
		local Logger = require("logger")
		local lines = {}
		local previous_level = Logger.get_level()
		Logger.set_level("debug")
		Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
		local dir = user_folder()
		write(dir .. "/rolls.toml", one_entry_pack("mine", "zqx", "my roll"))
		local ok, failure = pcall(load_with_user_folder, dir)
		os.remove(dir .. "/rolls.toml")
		os.remove(dir)
		Logger.set_sink(nil)
		Logger.set_level(previous_level)
		helpers.assert_true(ok, tostring(failure))
		local placeholder = require("diagnostics.private_label").PLACEHOLDER
		local seen = false
		for _, line in ipairs(lines) do
			if line:find("user's copy of", 1, true) then
				seen = true
				helpers.assert_true(line:find("'rolls'", 1, true) == nil, "the category name reached the log: " .. line)
				helpers.assert_true(line:find(placeholder, 1, true) ~= nil, "the line carries the placeholder: " .. line)
			end
		end
		helpers.assert_true(seen, "the override line must have been logged")
	end)

	helpers.it("(category-name-log-mask) pins the placeholder to the redaction policy", function()
		local file = assert(io.open(require("infra.paths").shared("modules/diagnostics/redaction.json"), "rb"))
		local policy = require("json").decode(file:read("*a"))
		file:close()
		require("test.private_label_contract")(helpers, policy)
	end)
end)
