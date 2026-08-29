--- tests/unit/modules/keymap/test_input_sources_probe_task_pin.lua

--- ==============================================================================
--- MODULE: Active-layout Probe Deadline Regression
--- DESCRIPTION:
--- A python3 layout probe that never completed kept the refresh flag set for the
--- entire Hammerspoon session. These tests exercise the real ShellRunner and
--- TimerScheduler adapters over faithful native doubles: the deadline must own
--- the child before start, terminate a hung probe, fence late completion, and
--- leave transient cleanup refusal retryable.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Clears every stateful module owned by this fixture.
local function reset_fixture_modules()
	package.loaded["modules.keymap.input_sources"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.task_lifecycle"] = nil
end


--- Loads input_sources with real lifecycle adapters and controllable natives.
--- @param options table|nil Native failure controls.
--- @return table fixture
local function load_fixture(options)
	options = options or {}
	reset_fixture_modules()

	local fixture = {
		order = {},
		tasks = {},
		timers = {},
	}

	local task_api = {}
	function task_api.new(executable, on_done, args)
		fixture.order[#fixture.order + 1] = "spawn"
		local task = {
			executable = executable,
			args = args,
			on_done = on_done,
			running = false,
			start_calls = 0,
			terminate_calls = 0,
		}
		function task:start()
			self.start_calls = self.start_calls + 1
			fixture.order[#fixture.order + 1] = "start"
			if options.task_start_result == false then return false end
			self.running = true
			return self
		end
		function task:isRunning() return self.running end
		function task:terminate()
			self.terminate_calls = self.terminate_calls + 1
			if options.terminate_results and #options.terminate_results > 0 then
				local result = table.remove(options.terminate_results, 1)
				if result == "nil" then return nil end
				if result == "throw" then error("injected terminate failure") end
				if result == false then return false end
			end
			return self
		end
		function task:complete(exit_code, stdout, stderr)
			self.running = false
			self.on_done(exit_code, stdout, stderr)
		end
		fixture.tasks[#fixture.tasks + 1] = task
		return task
	end

	local timer_api = {}
	function timer_api.new(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			stop_calls = 0,
		}
		function timer:start()
			fixture.order[#fixture.order + 1] = "deadline"
			local result = options.timer_start_results
				and table.remove(options.timer_start_results, 1)
			if result == false then return false end
			self.running_state = true
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			local result = options.timer_stop_results
				and table.remove(options.timer_stop_results, 1)
			if result == false then return false end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire() self.callback() end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end

	fixture.IS = helpers.load_with_stubs("modules.keymap.input_sources", {
		task = task_api,
		timer = timer_api,
	})
	return fixture
end


helpers.describe("active-layout probe: deadline owns the async child", function()
	helpers.it("times out one hung probe and fences its late completion", function()
		local f = load_fixture()
		local first_done = 0
		local joined_done = 0
		f.IS.refresh_active_layouts_async(function() first_done = first_done + 1 end)

		helpers.assert_eq(table.concat(f.order, ","), "spawn,deadline,start",
			"the watchdog must commit before python3 starts")
		helpers.assert_eq(#f.tasks, 1)
		helpers.assert_eq(#f.timers, 1)
		helpers.assert_eq(f.timers[1].delay, 10,
			"the probe must share the canonical input-source subprocess deadline")
		helpers.assert_eq(tonumber(f.tasks[1].args[3]), 9,
			"the nested defaults call must expire before its Python owner")
		helpers.assert_eq(first_done, 0)

		f.IS.refresh_active_layouts_async(function() joined_done = joined_done + 1 end)
		helpers.assert_eq(#f.tasks, 1, "a concurrent refresh must join the live owner")
		helpers.assert_eq(joined_done, 0,
			"joining a live probe must not announce a completion that did not happen")

		f.timers[1]:fire()
		helpers.assert_eq(f.tasks[1].terminate_calls, 1)
		helpers.assert_eq(first_done, 1)
		helpers.assert_eq(joined_done, 1)

		local successor_done = 0
		f.IS.refresh_active_layouts_async(function() successor_done = successor_done + 1 end)
		helpers.assert_eq(#f.tasks, 2,
			"an accepted timeout termination must release the read-only probe slot")
		helpers.assert_eq(successor_done, 0)

		f.tasks[1]:complete(0, '[["Old", "old.id", true]]', "")
		helpers.assert_eq(first_done, 1,
			"a late terminal from the timed-out owner must stay cleanup-only")
		local third_done = 0
		f.IS.refresh_active_layouts_async(function() third_done = third_done + 1 end)
		helpers.assert_eq(#f.tasks, 2,
			"the old callback must not clear its live successor")
		helpers.assert_eq(third_done, 0)

		f.tasks[2]:complete(0, '[["French", "fr.id", true]]', "")
		helpers.assert_eq(successor_done, 1)
		helpers.assert_eq(third_done, 1)
		reset_fixture_modules()
	end)

	helpers.it("retries an exact termination refusal before admitting a successor", function()
		local f = load_fixture({ terminate_results = { false, true } })
		local first_done = 0
		local retry_done = 0
		f.IS.refresh_active_layouts_async(function() first_done = first_done + 1 end)
		f.timers[1]:fire()

		helpers.assert_eq(f.tasks[1].terminate_calls, 1)
		helpers.assert_eq(first_done, 0,
			"a refused termination must retain the exact probe owner")
		f.IS.refresh_active_layouts_async(function() retry_done = retry_done + 1 end)
		helpers.assert_eq(f.tasks[1].terminate_calls, 2,
			"the next refresh must retry the exact retained child")
		helpers.assert_eq(#f.tasks, 1)
		helpers.assert_eq(first_done, 1)
		helpers.assert_eq(retry_done, 1)

		f.IS.refresh_active_layouts_async(nil)
		helpers.assert_eq(#f.tasks, 2)
		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")
		reset_fixture_modules()
	end)

	helpers.it("releases a refused timeout owner when the exact child exits itself", function()
		local f = load_fixture({ terminate_results = { false } })
		local done = 0
		f.IS.refresh_active_layouts_async(function() done = done + 1 end)
		f.timers[1]:fire()
		helpers.assert_eq(done, 0)
		helpers.assert_eq(f.tasks[1].terminate_calls, 1)

		f.tasks[1]:complete(1, "", "late native exit")
		helpers.assert_eq(done, 1,
			"the completion callback is also exact proof that no task remains")
		f.IS.refresh_active_layouts_async(nil)
		helpers.assert_eq(#f.tasks, 2)
		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")
		reset_fixture_modules()
	end)

	helpers.it("never starts a probe without a committed watchdog", function()
		local f = load_fixture({ timer_start_results = { false, true } })
		local first_done = 0
		f.IS.refresh_active_layouts_async(function() first_done = first_done + 1 end)

		helpers.assert_eq(#f.tasks, 1)
		helpers.assert_eq(f.tasks[1].start_calls, 0)
		helpers.assert_eq(first_done, 1)
		f.IS.refresh_active_layouts_async(nil)
		helpers.assert_eq(#f.tasks, 2,
			"a watchdog start refusal must leave the probe retryable")
		helpers.assert_eq(f.tasks[2].start_calls, 1)
		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")
		reset_fixture_modules()
	end)

	helpers.it("waits for deadline settlement before publishing normal completion", function()
		local f = load_fixture({ timer_stop_results = { false, true } })
		local done = 0
		f.IS.refresh_active_layouts_async(function() done = done + 1 end)
		f.tasks[1]:complete(0, '[["French", "fr.id", true]]', "")
		helpers.assert_eq(done, 0,
			"normal success must wait while watchdog cleanup remains owned")
		f.timers[1]:fire()
		helpers.assert_eq(done, 1)
		helpers.assert_eq(f.tasks[1].terminate_calls, 0,
			"cleanup-only timer delivery must not become a business timeout")
		reset_fixture_modules()
	end)
end)
