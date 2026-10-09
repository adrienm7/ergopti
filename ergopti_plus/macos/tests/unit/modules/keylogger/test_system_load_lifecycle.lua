--- tests/unit/modules/keylogger/test_system_load_lifecycle.lua

--- ==============================================================================
--- MODULE: System Load Completion Lifecycle Regression
--- DESCRIPTION:
--- Delivers real watcher task completions after runtime transitions and checks
--- that retired samples never append sensor events into a successor runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a system-load scenario with independently controlled native completion.
--- @param scenario function Scenario receiving watcher, shared state and fixture.
local function with_fixture(scenario)
	local names = {
		"infra.logger", "infra.timings", "adapters.task_lifecycle",
		"adapters.timer_scheduler", "modules.keylogger.log_manager",
		"modules.keylogger.watchers",
	}
	local saved, saved_hs = {}, _G.hs
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local fixture = { tasks = {}, events = {}, paused = false, now = 1000000000 }
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, success = noop, debug = noop, warn = noop, error = noop,
		pcall = function(_, callback) return pcall(callback) end,
	}
	package.loaded["infra.timings"] = { ms = function() return 1 end }
	package.loaded["adapters.timer_scheduler"] = { cancel = function() return true end }
	package.loaded["adapters.task_lifecycle"] = {
		native = function(_, _, callback)
			local task = { complete = callback }
			fixture.tasks[#fixture.tasks + 1] = task
			return task
		end,
		start = function() return true end,
	}
	package.loaded["modules.keylogger.log_manager"] = {
		log_system_event = function(kind, data)
			fixture.events[#fixture.events + 1] = { kind = kind, data = data }
		end,
	}
	_G.hs = { timer = { absoluteTime = function() return fixture.now end } }
	local ok, err = xpcall(function()
		local watcher = require("modules.keylogger.watchers")
		local state = { is_enabled = true, session_last_active = 0 }
		helpers.assert_true(watcher.init(state, function() return fixture.paused end))
		helpers.assert_true(watcher.init_hardware_watchers())
		watcher.check_idle()
		helpers.assert_eq(#fixture.tasks, 1)
		scenario(watcher, state, fixture)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	_G.hs = saved_hs
	if not ok then error(err, 0) end
end

helpers.describe("system-load-lifecycle", function()
	for _, transition in ipairs({ "pause", "disable", "stop", "restart" }) do
		helpers.it("rejects a system-load completion after " .. transition, function()
			with_fixture(function(watcher, state, fixture)
				if transition == "pause" then fixture.paused = true
				elseif transition == "disable" then state.is_enabled = false
				else
					helpers.assert_true(watcher.stop_hardware_watchers())
					if transition == "restart" then helpers.assert_true(watcher.init_hardware_watchers()) end
				end
				fixture.tasks[1].complete(0, "CPU usage: 10.0% user\nPhysMem: 8G used", "")
				helpers.assert_eq(#fixture.events, 0, "retired sensor result must not be persisted")
			end)
		end)
	end

	helpers.it("delivers a current sample after rejecting the retired generation", function()
		with_fixture(function(watcher, _, fixture)
			helpers.assert_true(watcher.stop_hardware_watchers())
			helpers.assert_true(watcher.init_hardware_watchers())
			fixture.now = fixture.now + 1000000000
			watcher.check_idle()
			helpers.assert_eq(#fixture.tasks, 2)
			fixture.tasks[1].complete(0, "CPU usage: 10.0% user", "")
			fixture.tasks[2].complete(0, "CPU usage: 20.0% user\nPhysMem: 8G used", "")
			helpers.assert_eq(#fixture.events, 1)
			helpers.assert_eq(fixture.events[1].kind, "system_load")
			helpers.assert_eq(fixture.events[1].data.cpu_user_percent, 20)
			helpers.assert_eq(fixture.events[1].data.mem_used, "8G")
		end)
	end)
end)
