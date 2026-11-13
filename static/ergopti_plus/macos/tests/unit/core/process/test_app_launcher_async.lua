--- tests/unit/core/process/test_app_launcher_async.lua

--- Verifies launchWithArgs hands exact argv to the asynchronous task owner.
local helpers = require("tests.helpers")

helpers.describe("application launch with arguments", function()
	helpers.it("keeps the actual task runner's child pinned until completion", function()
		helpers.with_stub_scope({ "adapters.app_launcher", "core.process.adapters.shell_runner" }, function()
			package.loaded["core.process.adapters.shell_runner"] = nil
			local callback, task
			local env = { HOME = "/tmp", PATH = "/usr/bin:/bin" }
			local launcher = helpers.load_with_stubs("adapters.app_launcher", {
				task = { new = function(_, done)
					callback = done
					task = {
						environment = function() return env end,
						setEnvironment = function(self, value) env = value; return self end,
						start = function(self) return self end,
					}
					return task
				end },
			})
			launcher.launchWithArgs("Safari", { "--example" })
			local runner = require("core.process.adapters.shell_runner")
			helpers.assert_eq(runner._active_tasks[task], true)
			callback(0, "", "")
			helpers.assert_eq(runner._active_tasks[task], nil)
		end)
	end)

	helpers.it("dispatches asynchronously without a shell", function()
		helpers.with_stub_scope({ "adapters.app_launcher", "core.process.adapters.shell_runner" }, function()
			local seen, started, sync_calls = nil, 0, 0
			package.loaded["core.process.adapters.shell_runner"] = { spawn = function(path, args)
				seen = { path = path, args = args }
				return { start = function() started = started + 1; return true end }
			end }
			local launcher = helpers.load_with_stubs("adapters.app_launcher", {
				execute = function() sync_calls = sync_calls + 1; return "", true, "exit", 0 end,
			})
			launcher.launchWithArgs("/Applications/My App.app", { "a; b", "$HOME", "" })
			helpers.assert_eq(sync_calls, 0)
			helpers.assert_eq(started, 1)
			helpers.assert_eq(seen.path, "/usr/bin/open")
			helpers.assert_eq(seen.args, { "-a", "/Applications/My App.app", "--args", "a; b", "$HOME", "" })
		end)
	end)
end)
