--- tests/unit/adapters/test_app_launcher_shell_quoting.lua

--- ==============================================================================
--- MODULE: Regression — app_launcher.launchWithArgs quotes shell arguments
--- DESCRIPTION:
--- Guards against the regression where launchWithArgs built the shell command as
--- string.format("open -a %q --args %s", app_path, args) with %s for the args.
--- Shell metacharacters (spaces, &, ;, $) in args would be interpreted by /bin/sh,
--- enabling command injection.
--- Each arg is now single-quote POSIX escaped via the shq() helper.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ launchWithArgs shell quoting =================================
-- =========================================================================
-- =========================================================================

helpers.describe("app_launcher: launchWithArgs shell quoting", function()
	helpers.it("source does not use bare %s for args in the shell command", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/app_launcher.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open app_launcher.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The old bug: args were passed directly as tostring(args) without quoting.
		-- The fix introduces a shq() helper; the command uses %s but passes quoted_args.
		-- Check that the raw args variable is NOT passed directly (must go through shq).
		helpers.assert_true(
			src:find('--args %s", app_path, tostring(args', 1, true) == nil,
			"launchWithArgs must not pass raw args to the shell command"
		)
		helpers.assert_true(
			src:find("quoted_args", 1, true) ~= nil,
			"launchWithArgs must build quoted_args via shq() before shell interpolation"
		)
	end)

	helpers.it("source has a single-quote POSIX escape helper (shq)", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/app_launcher.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open app_launcher.lua")
		local src = fh:read("*a")
		fh:close()

		helpers.assert_true(
			src:find("local function shq", 1, true) ~= nil,
			"launchWithArgs must define a shq() POSIX quoting helper"
		)
		helpers.assert_true(
			src:find([[gsub("'", "'\\''")]], 1, true) ~= nil or
			src:find("gsub(\"'\",", 1, true) ~= nil,
			"shq() must escape single quotes with '\\'' POSIX idiom"
		)
	end)
end)
