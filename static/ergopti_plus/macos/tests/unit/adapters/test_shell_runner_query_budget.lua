--- tests/unit/adapters/test_shell_runner_query_budget.lua

--- Literal start-frame controls; the existing seven-argument protocol keeps its cap.
local H = require("tests.helpers")

local function fixture(body)
	local old_hs = _G.hs
	local ok, failure = xpcall(function()
		H.with_fresh_modules({ "adapters.shell_runner", "infra.logger", "adapters.task_environment" }, function()
			package.loaded["infra.logger"] = H.make_logger_stub()
			local f = { tasks = {}, wire = string.rep("A", 1024) }
			_G.hs = { task = { new = function(_, terminal, chunks)
				local task = { running = false, environment_values = {} }
				function task:environment() return self.environment_values end
				function task:setEnvironment(value) self.environment_values = value; return self end
				function task:start() self.running = true; chunks(self, f.wire, ""); return self end
				function task:terminate() return self end
				function task:isRunning() return self.running end
				function task:closeInput() return self end
				function task:setInput() return self end
				function task:finish() self.running = false; terminal(0, "", "") end
				f.tasks[#f.tasks + 1] = task
				return task
			end } }
			f.runner = require("adapters.shell_runner")
			body(f)
			for _, task in ipairs(f.tasks) do if task.running then task:finish() end end
		end)
	end, debug.traceback)
	_G.hs = old_hs
	if not ok then error(failure, 0) end
end

H.describe("ShellRunner optional signed-query start budget", function()
	H.it("preserves the original seven-argument owned protocol cap", function()
		fixture(function(f)
			local delivered = {}
			local handle = f.runner.spawn("/signed/launcher", {}, function() end, function(_, stdout)
				delivered[#delivered + 1] = stdout; return true
			end, nil, true, true)
			H.assert_true(handle.start()); H.assert_eq(delivered, { "V1 INVALID\n" })
		end)
	end)
	H.it("retains an explicitly bounded query frame above the original program cap", function()
		fixture(function(f)
			local delivered = {}
			local handle = f.runner.spawn("/signed/launcher", {}, function() end, function(_, stdout)
				delivered[#delivered + 1] = stdout; return true
			end, nil, true, true, 90000)
			H.assert_true(handle.start()); H.assert_eq(delivered, { string.rep("A", 1024) })
		end)
	end)
	H.it("refuses invalid custom budgets before allocating a task", function()
		fixture(function(f)
			for _, budget in ipairs({ 511, 90001, 512.5, "90000" }) do
				local handle = f.runner.spawn("/signed/launcher", {}, nil, function() end, nil, true, true, budget)
				H.assert_eq(handle.start(), false)
			end
			local handle = f.runner.spawn("/signed/launcher", {}, nil, function() end, nil, true, false, 90000)
			H.assert_eq(handle.start(), false); H.assert_eq(#f.tasks, 0)
		end)
	end)
end)
