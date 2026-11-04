--- tests/unit/adapters/processes/test_app_launcher_shell_quoting.lua

--- ==============================================================================
--- MODULE: Regression — app_launcher.launchWithArgs quotes shell arguments
--- DESCRIPTION:
--- Guards against the regression where launchWithArgs built the shell command as
--- string.format("open -a %q --args %s", app_path, args) with %s for the args.
--- Shell metacharacters (spaces, &, ;, $, quotes) in args or in the application
--- path would be interpreted by /bin/sh, enabling command injection.
---
--- Behaviour, not spelling: the command the adapter hands to hs.execute is run by
--- a real /bin/sh with `open` replaced by a function printing its arguments, so
--- the test fails for any quoting that lets the shell split, expand or run a
--- part of an argument, whatever the code looks like.
--- ==============================================================================

local helpers = require("tests.helpers")

local SH = "/bin/sh"

--- Runs a command line through the real shell with `open` printing each argument
--- on its own line, framed so an empty argument stays visible.
--- @param command string Command handed to hs.execute.
--- @return table arguments The argument vector `open` received.
local function shell_arguments(command)
	local script = os.tmpname()
	local handle = assert(io.open(script, "wb"))
	handle:write("open() { for a in \"$@\"; do printf '<%s>\\n' \"$a\"; done; }\n", command, "\n")
	handle:close()
	local pipe = assert(io.popen(SH .. " '" .. script .. "'"))
	local output = pipe:read("*a")
	pipe:close()
	os.remove(script)
	local arguments = {}
	for argument in output:gmatch("<(.-)>\n") do arguments[#arguments + 1] = argument end
	return arguments
end

--- Loads the adapter with hs.execute recording the command it is given.
--- @return table launcher
--- @return table commands
local function launcher_recording()
	local commands = {}
	local launcher = helpers.load_with_stubs("adapters.app_launcher", {
		execute = function(command)
			commands[#commands + 1] = command
			return "", true, "exit", 0
		end,
	})
	return launcher, commands
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ launchWithArgs shell quoting =================================
-- =========================================================================
-- =========================================================================

helpers.describe("app_launcher: launchWithArgs shell quoting", function()
	local hostile = { "two words", "a;touch /tmp/pwned", "$HOME", "`id`", "it's", "a&b", "" }

	helpers.it("every argument reaches open exactly as given, none run or expanded", function()
		local launcher, commands = launcher_recording()
		launcher.launchWithArgs("/Applications/My App's $NAME.app", hostile)
		helpers.assert_eq(#commands, 1, "one command is handed to the shell")
		local received = shell_arguments(commands[1])
		local expected = { "-a", "/Applications/My App's $NAME.app", "--args" }
		for _, argument in ipairs(hostile) do expected[#expected + 1] = argument end
		helpers.assert_eq(#received, #expected, "the shell split or merged an argument: " .. commands[1])
		for index, argument in ipairs(expected) do
			helpers.assert_eq(received[index], argument, "argument " .. index .. " changed in the shell")
		end
	end)

	helpers.it("a single string argument stays one argument", function()
		local launcher, commands = launcher_recording()
		launcher.launchWithArgs("Safari", "--new-window; rm -rf ~")
		local received = shell_arguments(commands[1])
		helpers.assert_eq(#received, 4)
		helpers.assert_eq(received[4], "--new-window; rm -rf ~")
	end)
end)
