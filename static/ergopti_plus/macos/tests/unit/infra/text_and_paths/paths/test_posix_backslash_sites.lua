--- tests/unit/infra/text_and_paths/paths/test_posix_backslash_sites.lua

--- ==============================================================================
--- MODULE: Converted Path Sites Keep POSIX Backslash Bytes
--- DESCRIPTION:
--- Behavioural controls for sites that split real macOS paths through the
--- shared native path owner. On a modelled POSIX host a backslash inside a
--- file or folder name must survive: the former [/\\] classes cut it as a
--- separator (posix-backslash-separator-owner).
--- ==============================================================================

local helpers = require("tests.helpers")

local POSIX_CONFIG = "/\n;\n?\n!\n-\n"

--- Runs body with package.config modelling a POSIX host.
--- @param body function Scenario.
local function on_posix(body)
	local saved = package.config
	package.config = POSIX_CONFIG
	local ok, failure = xpcall(body, debug.traceback)
	package.config = saved
	if not ok then error(failure, 0) end
end

helpers.describe("converted path sites keep POSIX backslash bytes (posix-backslash-separator-owner)", function()
	helpers.it("posix-backslash-separator-owner: a group name keeps a backslash in its file name", function()
		local Preferences = helpers.load_with_stubs("infra.preferences")
		on_posix(function()
			helpers.assert_eq(Preferences.get_group_name("/Users/a/hotstrings/back\\slash.toml"), "back\\slash")
			helpers.assert_eq(Preferences.get_group_name("/Users/a/back\\slash/emoji.toml"), "emoji")
		end)
	end)
end)
