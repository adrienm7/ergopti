--- tests/unit/infra/test_app_picker_shell_runner_integration.lua

--- ==============================================================================
--- MODULE: Application Picker Process Integration
--- DESCRIPTION:
--- Exercises real discovery and process settlement through stateful native tasks.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

local function with_real_runner(mode, run)
	with_picker(function(_, state)
		helpers.with_fresh_modules({ "infra.app_picker", "adapters.shell_runner" }, function()
			local tasks = {}
			_G.hs.task = { new = function(_, completed)
				local first = #tasks == 0
				local task = helpers.attach_native_task_environment({ running = false, terminated = 0 })
				function task:complete(code, output)
					self.running = false
					completed(code, output, "")
				end
				function task:start()
					self.running = true
					if not first or mode == "interrupted" then return self end
					if mode == "synchronous" then self:complete(0, "/Applications/TooEarly.app\0") end
					if mode == "throw" then error("injected start refusal") end
					if mode == "nil" then return nil end
					return false
				end
				function task:terminate() self.terminated = self.terminated + 1; return false end
				function task:isRunning() return self.running end
				tasks[#tasks + 1] = task
				return task
			end }
			local runner = require("adapters.shell_runner")
			local picker = require("infra.app_picker")
			run(picker, runner, tasks, state)
		end)
	end)
end

helpers.describe("app_picker: real process adapter settlement", function()
	for _, mode in ipairs({ "false", "nil", "throw", "synchronous", "interrupted" }) do
		helpers.it("settles once and preserves successor task ownership after " .. mode, function()
			with_real_runner(mode, function(picker, runner, tasks)
				local receipts = {}
				local function receive(rows, success)
					receipts[#receipts + 1] = { rows = rows, success = success }
				end
				picker.discover_apps(receive)
				if mode == "interrupted" then tasks[1]:complete(15, "/Applications/Partial.app\0") end
				helpers.assert_eq(receipts, { { success = false } })
				local delayed = mode ~= "synchronous" and mode ~= "interrupted"
				helpers.assert_eq(runner._active_tasks[tasks[1]] == true, delayed)
				if delayed then helpers.assert_eq(tasks[1].terminated, 1) end
				picker.discover_apps(receive)
				helpers.assert_eq(#tasks, 2, "failure must not authorize a discovery cache")
				helpers.assert_eq(runner._active_tasks[tasks[2]], true)
				tasks[1]:complete(0, "/Applications/Late.app\0")
				tasks[1]:complete(0, "/Applications/Duplicate.app\0")
				helpers.assert_eq(#receipts, 1, "native late and duplicate completions must stay inert")
				helpers.assert_nil(runner._active_tasks[tasks[1]])
				helpers.assert_eq(runner._active_tasks[tasks[2]], true, "old completion must not release the successor")
				tasks[2]:complete(0, "/Applications/Recovered.app\0")
				helpers.assert_eq(#receipts, 2)
				helpers.assert_eq(receipts[2].success, true)
				helpers.assert_eq(receipts[2].rows[1].appPath, "/Applications/Recovered.app")
				helpers.assert_nil(next(runner._active_tasks), "all native task ownership must settle")
			end)
		end)
	end

	helpers.it("keeps refused menu discovery invisible and makes the recovered chooser usable", function()
		with_real_runner("false", function(picker, runner, tasks, state)
			local applied = {}
			local action = picker.build_menu({}, function(rows) applied[#applied + 1] = rows end)[1].action
			action()
			helpers.assert_eq(#state.choosers, 0)
			helpers.assert_eq(#applied, 0)
			action()
			helpers.assert_eq(#tasks, 2)
			tasks[1]:complete(0, "/Applications/Obsolete.app\0")
			helpers.assert_eq(#state.choosers, 0)
			tasks[2]:complete(0, "/Applications/Recovered.app\0")
			helpers.assert_eq(#state.choosers, 1)
			helpers.assert_eq(state.choosers[1].shown, 1)
			state.choosers[1].callback(state.choosers[1].rows[1])
			helpers.assert_eq(applied, { { { name = "Recovered", appPath = "/Applications/Recovered.app" } } })
			helpers.assert_eq(state.choosers[1].deleted, 1)
			helpers.assert_nil(next(runner._active_tasks))
		end)
	end)
end)
