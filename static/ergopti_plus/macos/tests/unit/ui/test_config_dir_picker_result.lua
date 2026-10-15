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


helpers.describe("config folder picker native refusal", function()
	for _, phase in ipairs({ "compile", "execute" }) do
		helpers.it("(config-dir-picker) " .. phase .. " failure cannot become a selected folder", function()
			local private_error = "{ NSAppleScriptErrorMessage = PRIVATE_NATIVE_" .. phase .. "; }"
			local MenuPaths = with_osascript(false, nil, private_error)
			local errors = {}
			package.loaded["infra.logger"].error = function(_, message)
				errors[#errors + 1] = message
			end
			helpers.assert_nil(MenuPaths.pick_config_dir("/Users/me/", "Prompt"),
				"a refused native script's diagnostic is not a filesystem selection")
			helpers.assert_eq(#errors, 1, "native failure must be visible through the logger")
			helpers.assert_nil(errors[1]:find("PRIVATE_NATIVE", 1, true),
				"the native diagnostic must not be exposed in the log")
		end)
	end

	helpers.it("(config-dir-picker) a successful raw descriptor retains its existing fallback", function()
		local MenuPaths = with_osascript(true, nil, '"/Users/me/Raw result/"')
		helpers.assert_eq(MenuPaths.pick_config_dir("/Users/me/", "Prompt"), "/Users/me/Raw result/")
	end)
end)
