--- tests/unit/ui/test_config_dir_picker_result.lua

--- ==============================================================================
--- MODULE: Config Folder Picker Result
--- DESCRIPTION:
--- Proves the shared native folder picker reads the parsed AppleScript result.
--- hs.osascript.applescript returns (ok, parsed_object, raw_descriptor), where
--- the raw descriptor of a text result keeps its AppleScript quotes. The
--- onboarding wizard's former copy of the picker read only that descriptor.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_fixture = require("tests.support.paths_editor_fixture")


--- Loads the paths editor behind a scripted osascript result.
--- @param ok boolean Script success flag.
--- @param object any Parsed result.
--- @param raw any Raw descriptor.
--- @return table module
--- @return table seen Captured script source.
local function with_osascript(ok, object, raw)
	local seen = {}
	local MenuPaths = load_fixture()
	hs.osascript = { applescript = function(script)
		seen.script = script
		return ok, object, raw
	end }
	hs.fs.attributes = function() return { mode = "directory" } end
	return MenuPaths, seen
end


helpers.describe("config folder picker result", function()
	helpers.it("(config-dir-picker) the parsed result wins over the quoted raw descriptor", function()
		local MenuPaths = with_osascript(true, "/Users/me/Ergopti Data/", '"/Users/me/Ergopti Data/"')
		helpers.assert_eq(MenuPaths.pick_config_dir("/Users/me/", "Prompt"), "/Users/me/Ergopti Data/")
	end)

	helpers.it("(config-dir-picker) a result without trailing slash gains one", function()
		local MenuPaths = with_osascript(true, "/Users/me/data", '"/Users/me/data"')
		helpers.assert_eq(MenuPaths.pick_config_dir("/Users/me/", "Prompt"), "/Users/me/data/")
	end)

	helpers.it("(config-dir-picker) a cancelled dialog yields nil", function()
		local MenuPaths = with_osascript(true, "", '""')
		helpers.assert_nil(MenuPaths.pick_config_dir("/Users/me/", "Prompt"))
	end)

	helpers.it("(config-dir-picker) the caller's prompt and seed reach the script", function()
		local MenuPaths, seen = with_osascript(true, "/x/", '"/x/"')
		MenuPaths.pick_config_dir("/Users/me/seed/", "Choose the wizard folder")
		helpers.assert_true(seen.script:find("Choose the wizard folder", 1, true) ~= nil)
		helpers.assert_true(seen.script:find("/Users/me/seed/", 1, true) ~= nil)
	end)

	helpers.it("(config-dir-picker) an empty seed opens at the current config directory", function()
		local MenuPaths, seen = with_osascript(true, "/x/", '"/x/"')
		MenuPaths.pick_config_dir("", "Prompt")
		helpers.assert_true(seen.script:find("/tmp/ergopti/", 1, true) ~= nil, seen.script)
	end)
end)
