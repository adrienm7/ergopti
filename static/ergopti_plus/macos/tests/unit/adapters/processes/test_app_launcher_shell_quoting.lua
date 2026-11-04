--- tests/unit/adapters/processes/test_app_launcher_shell_quoting.lua

--- ==============================================================================
--- MODULE: App launcher argument boundaries
--- DESCRIPTION:
--- Hostile words must reach the native argv unchanged without shell evaluation.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_launcher(scenario)
	helpers.with_stub_scope({ "adapters.app_launcher", "adapters.shell_runner" }, function()
		local received
		package.loaded["adapters.shell_runner"] = { spawn = function(path, args)
			received = { path = path, args = args }
			return { start = function() return true end }
		end }
		local launcher = helpers.load_with_stubs("adapters.app_launcher")
		scenario(launcher, function() return received end)
	end)
end

helpers.describe("app_launcher: exact argument boundaries", function()
	helpers.it("passes each hostile argument as one native argv element", function()
		with_launcher(function(launcher, observed)
			local hostile = { "two words", "a;touch /tmp/pwned", "$HOME", "`id`", "it's", "a&b", "" }
			launcher.launchWithArgs("/Applications/My App's $NAME.app", hostile)
			local received = observed()
			local expected = { "-a", "/Applications/My App's $NAME.app", "--args" }
			for _, argument in ipairs(hostile) do expected[#expected + 1] = argument end
			helpers.assert_eq(received.path, "/usr/bin/open")
			helpers.assert_eq(received.args, expected)
		end)
	end)

	helpers.it("keeps one string argument in one native argv element", function()
		with_launcher(function(launcher, observed)
			launcher.launchWithArgs("Safari", "--new-window; rm -rf ~")
			helpers.assert_eq(observed().args, { "-a", "Safari", "--args", "--new-window; rm -rf ~" })
		end)
	end)
end)
