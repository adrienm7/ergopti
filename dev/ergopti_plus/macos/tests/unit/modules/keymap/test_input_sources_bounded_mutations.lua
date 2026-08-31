--- tests/unit/modules/keymap/test_input_sources_bounded_mutations.lua

--- ==============================================================================
--- MODULE: Input-source Mutation Deadline Regression
--- DESCRIPTION:
--- Layout selection, activation, and migration used synchronous subprocesses.
--- Deferring those calls left the menu callback but still blocked Hammerspoon's
--- only runloop indefinitely. These tests exercise the real subprocess and timer
--- adapters over faithful native doubles, proving that every mutation starts
--- only after a deadline commits and retains its exact owner through timeout.
--- ==============================================================================

local helpers = require("tests.helpers")

local LOCALISED_NAME = "Ergopti+"
local KL_NAME = "Ergopti_v2_2_2_plus"
local RAW_ID = "com.apple.keyboardlayout.ergopti.plus"


--- Clears every stateful module owned by this test fixture.
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
			terminate_calls = 0,
		}
		function task:start()
			fixture.order[#fixture.order + 1] = "start"
			if options.task_start_mutates == true then self.running = true end
			if options.task_start_result == false then return false end
			self.running = true
			return self
		end
		function task:isRunning() return self.running end
		function task:terminate()
			self.terminate_calls = self.terminate_calls + 1
			if options.task_terminate_result == false then return false end
			if options.task_terminate_completes == true then
				self:complete(0, "OK\n", "")
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
			is_running = false,
			stop_calls = 0,
		}
		function timer:start()
			fixture.order[#fixture.order + 1] = "deadline"
			if options.timer_start_result == false then return false end
			self.is_running = true
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			local stop_result = options.timer_stop_results
				and table.remove(options.timer_stop_results, 1)
			if stop_result == false then return false end
			self.is_running = false
			return self
		end
		function timer:running() return self.is_running end
		function timer:fire() self.callback() end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end

	local IS = helpers.load_with_stubs("modules.keymap.input_sources", {
		task = task_api,
		timer = timer_api,
		execute = function()
			error("synchronous hs.execute reached")
		end,
	})
	hs.keycodes.setLayout = function() return false end
	fixture.IS = IS
	return fixture
end


helpers.describe("input-source mutations: deadline owns the subprocess", function()
	helpers.it("times out a hung selection without blocking or accepting a sibling", function()
		local f = load_fixture()
		local terminals = {}
		local mutation = f.IS.set_input_source_async
		local accepted = mutation(LOCALISED_NAME, KL_NAME, function(ok, _out, reason)
			terminals[#terminals + 1] = { ok = ok, reason = reason }
		end)

		helpers.assert_eq(accepted, true, "the asynchronous selection must be dispatched")
		helpers.assert_eq(table.concat(f.order, ","), "spawn,deadline,start",
			"the deadline must commit before the subprocess starts")
		helpers.assert_eq(#f.tasks, 1)
		helpers.assert_eq(#f.timers, 1)
		helpers.assert_eq(f.timers[1].delay, 10,
			"the native deadline must come from ui.input_source_operation_timeout_ms")
		helpers.assert_eq(#terminals, 0, "a live child has no business terminal yet")

		f.timers[1]:fire()
		helpers.assert_eq(f.tasks[1].terminate_calls, 1,
			"the deadline must terminate the exact child once")
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, false)
		helpers.assert_eq(terminals[1].reason, "timeout")

		local set_layout_calls = 0
		hs.keycodes.setLayout = function()
			set_layout_calls = set_layout_calls + 1
			return true
		end
		local sibling_terminals = 0
		local sibling_accepted = mutation(LOCALISED_NAME, KL_NAME, function(ok)
			sibling_terminals = sibling_terminals + 1
			helpers.assert_eq(ok, false)
		end)
		helpers.assert_eq(sibling_accepted, false,
			"an accepted terminate is pending until native completion")
		helpers.assert_eq(sibling_terminals, 1)
		helpers.assert_eq(#f.tasks, 1, "no overlapping native mutation may start")
		helpers.assert_eq(set_layout_calls, 0,
			"the busy owner must reject before an in-process setLayout attempt")

		f.tasks[1]:complete(0, "OK\n", "")
		helpers.assert_eq(#terminals, 1,
			"a late successful completion must not replace the timeout terminal")

		hs.keycodes.setLayout = function() return false end
		local retry_terminals = 0
		local retry_accepted = mutation(LOCALISED_NAME, KL_NAME, function()
			retry_terminals = retry_terminals + 1
		end)
		helpers.assert_eq(retry_accepted, true,
			"the next mutation may start after exact native settlement")
		helpers.assert_eq(#f.tasks, 2)
		helpers.assert_eq(retry_terminals, 0)
		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")

		reset_fixture_modules()
	end)

	helpers.it("retains the mutation slot until a fired deadline timer really settles", function()
		local f = load_fixture({ timer_stop_results = { false, false, true } })
		local terminals = {}
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end), true)

		f.timers[1]:fire()
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].reason, "timeout")
		f.tasks[1]:complete(1, "", "terminated")

		local busy_calls = 0
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				busy_calls = busy_calls + 1
				helpers.assert_eq(ok, false)
				helpers.assert_eq(reason, "busy")
			end), false,
			"task settlement alone must not release a retained deadline timer")
		helpers.assert_eq(busy_calls, 1)
		helpers.assert_eq(#f.tasks, 1)

		f.timers[1]:fire()
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function() end), false,
			"a second native stop refusal must keep the exact owner fenced")
		f.timers[1]:fire()
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function() end), true,
			"a successor may start only after TimerScheduler reports exact settlement")
		helpers.assert_eq(#f.tasks, 2)

		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")
		reset_fixture_modules()
	end)

	helpers.it("routes selection, enable, and upgrade through the same owned boundary", function()
		local cases = {
			{
				label = "selection",
				executable = "/usr/bin/osascript",
				invoke = function(IS, done)
					return IS.set_input_source_async(LOCALISED_NAME, KL_NAME, done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "-e")
				end,
			},
			{
				label = "enable",
				executable = "/usr/bin/python3",
				invoke = function(IS, done)
					return IS.enable_and_select_source_async(
						RAW_ID, "Ergopti+", "/tmp/Ergopti.bundle", "Ergopti", done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "-c")
					helpers.assert_eq(args[3], "/tmp/Ergopti.bundle")
					helpers.assert_eq(args[4], "Ergopti")
					helpers.assert_eq(tonumber(args[5]), 9,
						"the nested supervisor must finish before the outer owned deadline")
				end,
			},
			{
				label = "upgrade",
				executable = "/usr/bin/osascript",
				invoke = function(IS, done)
					return IS.upgrade_active_list_async({ "Ergopti_v2_2_1_plus" }, done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "-e")
				end,
			},
		}

		for _, case in ipairs(cases) do
			local f = load_fixture()
			local terminals = {}
			local accepted = case.invoke(f.IS, function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end)
			helpers.assert_eq(accepted, true, case.label .. " must dispatch asynchronously")
			helpers.assert_eq(table.concat(f.order, ","), "spawn,deadline,start",
				case.label .. " must arm its deadline before native start")
			helpers.assert_eq(#f.tasks, 1)
			helpers.assert_eq(f.tasks[1].executable, case.executable)
			case.assert_args(f.tasks[1].args)
			helpers.assert_eq(#terminals, 0)

			f.timers[1]:fire()
			helpers.assert_eq(#terminals, 1)
			helpers.assert_eq(terminals[1].ok, false)
			helpers.assert_eq(terminals[1].reason, "timeout")
			f.tasks[1]:complete(1, "", "terminated")
			reset_fixture_modules()
		end
	end)

	helpers.it("publishes each operation's success only after its business payload validates", function()
		local cases = {
			{
				label = "selection",
				stdout = "OK\n",
				invoke = function(IS, done)
					return IS.set_input_source_async(LOCALISED_NAME, KL_NAME, done)
				end,
			},
			{
				label = "enable",
				stdout = "ALREADY_PRESENT\n",
				invoke = function(IS, done)
					return IS.enable_and_select_source_async(
						RAW_ID, "Ergopti+", "/tmp/Ergopti.bundle", "Ergopti", done)
				end,
			},
			{
				label = "upgrade",
				stdout = "1/2\n",
				invoke = function(IS, done)
					return IS.upgrade_active_list_async({ "Ergopti_v2_2_1_plus" }, done)
				end,
			},
		}

		for _, case in ipairs(cases) do
			local f = load_fixture()
			local terminals = {}
			helpers.assert_eq(case.invoke(f.IS, function(ok, out, reason)
				terminals[#terminals + 1] = { ok = ok, out = out, reason = reason }
			end), true)
			helpers.assert_eq(#terminals, 0)
			f.tasks[1]:complete(0, case.stdout, "")
			helpers.assert_eq(#terminals, 1, case.label .. " must publish once")
			helpers.assert_eq(terminals[1].ok, true, case.label .. " payload must validate")
			helpers.assert_eq(terminals[1].reason, nil)
			reset_fixture_modules()
		end
	end)

	helpers.it("rejects success-looking payloads that are not the exact child protocol", function()
		local cases = {
			{
				stdout = "NOT_OK\n",
				invoke = function(IS, done)
					return IS.set_input_source_async(LOCALISED_NAME, KL_NAME, done)
				end,
			},
			{
				stdout = "OKAY\n",
				invoke = function(IS, done)
					return IS.enable_and_select_source_async(
						RAW_ID, "Ergopti+", "/tmp/Ergopti.bundle", "Ergopti", done)
				end,
			},
			{
				stdout = "prefix 1/2 suffix\n",
				invoke = function(IS, done)
					return IS.upgrade_active_list_async({ "Ergopti_v2_2_1_plus" }, done)
				end,
			},
		}

		for _, case in ipairs(cases) do
			local f = load_fixture()
			local terminal = nil
			helpers.assert_eq(case.invoke(f.IS, function(ok, _out, reason)
				terminal = { ok = ok, reason = reason }
			end), true)
			f.tasks[1]:complete(0, case.stdout, "")
			helpers.assert_not_nil(terminal)
			helpers.assert_eq(terminal.ok, false)
			helpers.assert_eq(terminal.reason, "invalid_output")
			reset_fixture_modules()
		end
	end)

	helpers.it("waits for exact deadline cleanup before publishing normal completion", function()
		local f = load_fixture({ timer_stop_results = { false, true } })
		local terminals = {}
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end), true)

		f.tasks[1]:complete(0, "OK\n", "")
		helpers.assert_eq(#terminals, 0,
			"a success must wait while the exact deadline timer refuses cleanup")
		f.timers[1]:fire()
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, true)
		helpers.assert_eq(terminals[1].reason, nil)
		helpers.assert_eq(f.tasks[1].terminate_calls, 0,
			"a cleanup-only timer delivery must not become a business timeout")
		reset_fixture_modules()
	end)

	helpers.it("never starts a child when the deadline capability refuses", function()
		local f = load_fixture({ timer_start_result = false })
		local terminals = {}
		local accepted = f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end)

		helpers.assert_eq(accepted, false)
		helpers.assert_eq(table.concat(f.order, ","), "spawn,deadline")
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, false)
		helpers.assert_eq(terminals[1].reason, "deadline_unavailable")
		helpers.assert_eq(f.tasks[1].running, false)
		reset_fixture_modules()
	end)

	helpers.it("retains activated start-failure debt through task and timer settlement", function()
		local options = {
			task_start_result = false,
			task_start_mutates = true,
			task_terminate_result = false,
			timer_stop_results = { false, true },
		}
		local f = load_fixture(options)
		local terminals = {}
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end), false)
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, false)
		helpers.assert_eq(terminals[1].reason, "start_failed")
		helpers.assert_eq(f.tasks[1].terminate_calls, 1)

		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function() end), false, "the mutated task remains the exact owner")
		f.tasks[1]:complete(1, "", "failed start settled")
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function() end), false, "timer cleanup debt still blocks after task settlement")
		f.timers[1]:fire()

		options.task_start_result = true
		options.task_start_mutates = false
		options.task_terminate_result = nil
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function() end), true, "both exact settlements release the successor")
		f.timers[2]:fire()
		f.tasks[2]:complete(1, "", "terminated")
		reset_fixture_modules()
	end)

	helpers.it("fences timeout before a hostile synchronous terminate completion", function()
		local f = load_fixture({ task_terminate_completes = true })
		local terminals = {}
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
			function(ok, _out, reason)
				terminals[#terminals + 1] = { ok = ok, reason = reason }
			end), true)
		f.timers[1]:fire()
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, false)
		helpers.assert_eq(terminals[1].reason, "timeout")
		helpers.assert_eq(f.tasks[1].terminate_calls, 1)
		reset_fixture_modules()
	end)
end)
