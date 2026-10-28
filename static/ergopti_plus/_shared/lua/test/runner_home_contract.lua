--- _shared/lua/test/runner_home_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Runner Home Isolation Contract
--- DESCRIPTION:
--- Replays the home isolation rules on both interpreter families with a fake
--- environment, so no test ever depends on the account running it.
--- ==============================================================================

local Home = require("test.runner_home")
local M = {}

local function environment(values)
	local env = { exited = nil }
	env.getenv = function(name) return values[name] end
	env.exit = function(code) env.exited = code end
	return env
end

--- Registers the isolation checks in each driver's existing runner owner.
--- @param helpers table Actual driver's describe/it/assertion functions.
function M.run(helpers)
	helpers.describe("Lua runner home isolation", function()
		helpers.it("Lua home: a real home is replaced and its XDG directories are hidden", function()
			local env = environment({ HOME = "/home/someone", XDG_CONFIG_HOME = "/home/someone/.config", USER = "someone" })
			local home, redirected = Home.isolate(env)
			helpers.assert_true(redirected, "a real home must be redirected")
			helpers.assert_true(home ~= "/home/someone", "the scratch home must differ from the real one")
			helpers.assert_eq(env.getenv("HOME"), home)
			helpers.assert_eq(env.getenv("USERPROFILE"), home)
			helpers.assert_nil(env.getenv("XDG_CONFIG_HOME"), "an XDG directory would point back at the real tree")
			helpers.assert_eq(env.getenv("USER"), "someone", "other variables pass through")
			local probe = io.open(home .. "/.ergopti_home_probe", "r")
			helpers.assert_true(probe ~= nil, "the scratch home must exist")
			if probe then probe:close() end
			env.exit(0)
			helpers.assert_eq(env.exited, 0, "the wrapped exit still exits")
			local after = io.open(home .. "/.ergopti_home_probe", "r")
			if after then after:close() end
			helpers.assert_nil(after, "the scratch home is removed when the runner exits")
		end)

		helpers.it("Lua home: an XDG directory inside a temporary directory stays visible", function()
			local env = environment({ HOME = "/home/someone", XDG_DATA_HOME = "/tmp/xdg-data" })
			Home.isolate(env)
			helpers.assert_eq(env.getenv("XDG_DATA_HOME"), "/tmp/xdg-data", "a test may own an XDG scratch tree")
			env.exit(0)
		end)

		helpers.it("Lua home: a missing or empty HOME is replaced rather than trusted", function()
			for _, value in ipairs({ "", false }) do
				local env = environment({ HOME = value or nil })
				local _, redirected = Home.isolate(env)
				helpers.assert_true(redirected)
				env.exit(0)
			end
		end)

		helpers.it("Lua home: a home inside a temporary directory is kept", function()
			for _, home in ipairs({ "/tmp/ci-home", "/private/var/folders/ab/T/home" }) do
				local env = environment({ HOME = home })
				local resolved, redirected = Home.isolate(env)
				helpers.assert_eq(redirected, false)
				helpers.assert_eq(resolved, home)
				helpers.assert_eq(env.getenv("HOME"), home)
			end
			local env = environment({ HOME = "/scratch/run/home", TMPDIR = "/scratch/run/" })
			helpers.assert_eq(select(2, Home.isolate(env)), false, "TMPDIR counts as a temporary root")
		end)

		helpers.it("Lua home: a shell child of an interpreter that cannot setenv gets the scratch home", function()
			local env = environment({ HOME = "/home/someone", XDG_DATA_HOME = "/home/someone/.local/share",
				XDG_STATE_HOME = "/tmp/own-state" })
			local seen = {}
			env.popen = function(command, mode) seen[#seen + 1] = { command = command, mode = mode }; return "handle" end
			env.execute = function(command) seen[#seen + 1] = { command = command }; return true end
			local home = Home.isolate(env)
			helpers.assert_eq(env.popen("echo $HOME", "r"), "handle")
			local command = seen[1].command
			helpers.assert_eq(seen[1].mode, "r", "the mode passes through")
			helpers.assert_true(command:find("export HOME='" .. home .. "'; ", 1, true) == 1,
				"the child must start with the scratch HOME: " .. command)
			helpers.assert_true(command:find("unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME; ", 1, true) ~= nil,
				"a real or unset XDG directory is hidden from the child")
			helpers.assert_true(command:find("XDG_STATE_HOME", 1, true) == nil, "a scratch XDG directory stays visible")
			helpers.assert_true(command:sub(-#"echo $HOME") == "echo $HOME", "the command itself is unchanged")
			env.execute("true")
			helpers.assert_true(seen[2].command:find("export HOME=", 1, true) == 1, "os.execute is wrapped too")
			env.execute()
			helpers.assert_eq(#seen, 3)
			helpers.assert_nil(seen[3].command, "the shell probe os.execute() stays a bare probe")
			env.exit(0)
		end)

		helpers.it("Lua home: a child interpreter that exports its environment is not wrapped", function()
			local env = environment({ HOME = "/home/someone" })
			local seen
			env.popen = function(command) seen = command end
			env.execute = function() end
			env.exports_environment = true
			Home.isolate(env)
			env.popen("echo $HOME")
			helpers.assert_eq(seen, "echo $HOME")
			env.exit(0)
		end)

		helpers.it("Lua home: a shell child sees the scratch home, never the account's", function()
			local pipe = assert(io.popen("printf %s \"$HOME\"", "r"))
			local child_home = pipe:read("*a")
			pipe:close()
			helpers.assert_eq(child_home, os.getenv("HOME"), "io.popen must inherit the runner's HOME")
		end)

		helpers.it("Lua home: the runner itself resolves a scratch home, never the account's own", function()
			helpers.assert_true(Home.is_scratch(os.getenv("HOME"), os.getenv),
				"tests/run.lua must isolate HOME before loading any test: " .. tostring(os.getenv("HOME")))
		end)

		helpers.it("Lua home: a path that climbs out of the temporary directory is a real home", function()
			helpers.assert_eq(Home.is_scratch("/tmp/../root", os.getenv), false)
			helpers.assert_eq(Home.is_scratch("/tmpfoo", os.getenv), false, "a sibling prefix is not inside /tmp")
			helpers.assert_eq(Home.is_scratch("/root", os.getenv), false)
		end)
	end)
end

return M
