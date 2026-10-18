--- tests/unit/modules/keymap/layout/test_input_sources_bounded_mutations.lua

--- ==============================================================================
--- MODULE: Input-source Mutation Deadline Regression
--- DESCRIPTION:
--- Layout selection, activation, and migration used synchronous subprocesses.
--- Deferring those calls left the menu callback but still blocked Hammerspoon's
--- only runloop indefinitely. These tests exercise the real subprocess and timer
--- adapters over faithful native doubles, proving that every mutation starts
--- only after a deadline commits and retains its exact owner through timeout.
--- Carbon mutation refusal is an OSStatus, independent of child process exit.
--- Preserve that status across selection and check every migration mutation
--- before its script can publish success (tis-osstatus).
--- Discover every replacement before disabling a working legacy source: a
--- predictable missing target must not partially mutate the enabled list.
--- ==============================================================================

local helpers = require("tests.helpers")

local LOCALISED_NAME = "Ergopti+"
local KL_NAME = "Ergopti_v2_2_2_plus"
local KEYLAYOUT_PATH = "/tmp/Ergopti.bundle/Contents/Resources/Ergopti_v2_2_2_plus.keylayout"
local NATIVE_HELPER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"


--- Clears every stateful module owned by this test fixture.
local function reset_fixture_modules()
	package.loaded["modules.keymap.input_sources"] = nil
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["adapters.input_source_selector"] = nil
	package.loaded["platform.remap.lease_helper"] = nil
end


--- Loads input_sources with real lifecycle adapters and controllable natives.
--- @param options table|nil Native failure controls.
--- @return table fixture
local function load_fixture(options)
	options = options or {}
	reset_fixture_modules()
	package.loaded["platform.remap.lease_helper"] = {
		resolve = function()
			if options.helper_unavailable == true then return nil, "helper_unavailable" end
			return NATIVE_HELPER, nil, {
				ERGOPTI_LAUNCHER_EXECUTABLE = NATIVE_HELPER,
				ERGOPTI_LAUNCHER_DEVICE = "1",
				ERGOPTI_LAUNCHER_INODE = "2",
			}
		end,
	}

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
			env = {},
		}
		function task:environment() return self.env end
		function task:setEnvironment(environment) self.env = environment; return self end
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
				self:complete(0, "0\n", "")
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


--- Keeps native-status probes independent of earlier fixtures in this module.
--- @param name string Regression description.
--- @param body function Fixture construction and assertions.
local function status_test(name, body)
	helpers.it(name, function()
		helpers.with_stub_scope({
			"modules.keymap.input_sources", "modules.keymap.layout_install",
			"adapters.shell_runner", "adapters.timer_scheduler", "adapters.task_lifecycle",
			"adapters.python_interpreter", "infra.openstep_plist",
			"adapters.input_source_selector", "platform.remap.lease_helper",
		}, body)
	end)
end


helpers.describe("input-source mutations: deadline owns the subprocess", function()
	status_test("(tis-osstatus) publishes selection only for the native success status", function()
		local cases = {
			{ stdout = "0\n", exit_code = 0, ok = true },
			{ stdout = "-50\n", exit_code = 0, ok = false },
			{ stdout = "1\n", exit_code = 0, ok = false },
			{ stdout = "OK\n", exit_code = 0, ok = false },
			{ stdout = "MISS\n", exit_code = 0, ok = false },
			{ stdout = "0\n", exit_code = 1, ok = false },
		}
		for _, case in ipairs(cases) do
			local f = load_fixture()
			local terminals = {}
			helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME,
				function(ok, out, reason)
					terminals[#terminals + 1] = { ok = ok, out = out, reason = reason }
				end), true)
			f.tasks[1]:complete(case.exit_code, case.stdout, "")
			helpers.assert_eq(#terminals, 1, "each native result must settle exactly once")
			helpers.assert_eq(terminals[1].ok, case.ok,
				"selection must honor the native OSStatus: " .. case.stdout)
			helpers.assert_eq(terminals[1].out, case.stdout:gsub("[\r\n]+$", ""))
			reset_fixture_modules()
		end
	end)

	status_test("(tis-native-selector) invokes the bundle helper with the exact source argv and identity", function()
		local f = load_fixture()
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME, function() end), true)
		helpers.assert_eq(f.tasks[1].executable, NATIVE_HELPER)
		helpers.assert_eq(#f.tasks[1].args, 2)
		helpers.assert_eq(f.tasks[1].args[1], "--select-input-source")
		helpers.assert_eq(f.tasks[1].args[2], KL_NAME)
		helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_EXECUTABLE, NATIVE_HELPER)
		helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_DEVICE, "1")
		helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_INODE, "2")
		f.tasks[1]:complete(0, "0\n", "")
		reset_fixture_modules()
	end)

	status_test("(tis-native-selector) refuses an unavailable exact helper without spawning", function()
		local f = load_fixture({ helper_unavailable = true })
		local terminal
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME, function(ok, _, reason)
			terminal = { ok = ok, reason = reason }
		end), false)
		helpers.assert_eq(#f.tasks, 0)
		helpers.assert_eq(#f.timers, 0)
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_eq(terminal.reason, "helper_unavailable")
		reset_fixture_modules()
	end)

	status_test("(tis-osstatus) checks every native migration mutation before counting success", function()
		local f = load_fixture()
		helpers.assert_eq(f.IS.upgrade_active_list_async({ "com.apple.keylayout.ergopti.plus" }, function() end), true)
		local script = f.tasks[1].args[2]
		for _, operation in ipairs({ "TISDisableInputSource", "TISEnableInputSource", "TISSelectInputSource" }) do
			helpers.assert_true(script:find("set nativeStatus to current application's " .. operation .. "(", 1, true) ~= nil,
				operation .. " must expose its native status")
			helpers.assert_true(script:find('if nativeStatus is not 0 then return "' .. operation .. ':" & (nativeStatus as text)', 1, true) ~= nil,
				operation .. " refusal must stop migration before success is published")
		end
		f.tasks[1]:complete(0, "1/1\n", "")
		reset_fixture_modules()
	end)

	status_test("(tis-partial-upgrade) requires every requested replacement before reporting success", function()
		local cases = {
			{ requested = 2, stdout = "1/1\n", ok = false },
			{ requested = 2, stdout = "1/2\n", ok = true },
			{ requested = 1, stdout = "1/2\n", ok = false },
			{ requested = 2, stdout = "2/2\n", ok = true },
			{ requested = 2, stdout = "0/0\n", ok = false },
		}
		for _, case in ipairs(cases) do
			local f = load_fixture()
			local entries = { "com.apple.keylayout.ergopti.plus" }
			if case.requested == 2 then entries[2] = "com.apple.keylayout.ergopti.ansi" end
			local terminal = nil
			helpers.assert_eq(f.IS.upgrade_active_list_async(entries, function(ok)
				terminal = ok
			end), true)
			f.tasks[1]:complete(0, case.stdout, "")
			helpers.assert_eq(terminal, case.ok,
				"the native enabled count must equal the requested replacement count")
			reset_fixture_modules()
		end
	end)

	status_test("(tis-target-preflight) resolves every replacement before mutating native sources", function()
		local f = load_fixture()
		local entries = { "com.apple.keylayout.ergopti.plus", "com.apple.keylayout.ergopti.ansi" }
		helpers.assert_eq(f.IS.upgrade_active_list_async(entries, function() end), true)
		local script = f.tasks[1].args[2]
		local first_mutation = #script + 1
		for _, operation in ipairs({ "TISDisableInputSource", "TISEnableInputSource", "TISSelectInputSource" }) do
			local at = script:find("current application's " .. operation .. "(", 1, true)
			helpers.assert_not_nil(at, "the script must retain " .. operation)
			first_mutation = math.min(first_mutation, at)
		end
		local preflight = script:sub(1, first_mutation - 1)
		for _, target in ipairs({ "com.apple.keyboardlayout.ergopti.plus", "com.apple.keyboardlayout.ergopti.ansi" }) do
			helpers.assert_true(preflight:find('my findSource("' .. target .. '")', 1, true) ~= nil,
				"every requested replacement must be discovered before any native mutation: " .. target)
		end
		local _, refusals = preflight:gsub('if targetSrc is missing value then return "MISS"', "")
		helpers.assert_eq(refusals, #entries, "each missing target must refuse before a legacy source can be disabled")
		for index = 1, #entries do
			helpers.assert_true(script:find("set newSrc to item " .. index .. " of targetSources", 1, true) ~= nil,
				"mutation must use the exact replacement retained by preflight")
		end
		f.tasks[1]:complete(0, "2/2\n", "")
		reset_fixture_modules()
	end)

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

		f.tasks[1]:complete(0, "0\n", "")
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
				executable = NATIVE_HELPER,
				invoke = function(IS, done)
					return IS.set_input_source_async(LOCALISED_NAME, KL_NAME, done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "--select-input-source")
				end,
			},
			{
				label = "enable",
				executable = helpers.HEALTHY_PYTHON,
				invoke = function(IS, done)
					return IS.enable_keylayout_source_async(KEYLAYOUT_PATH, "Ergopti+", done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "-c")
					helpers.assert_eq(args[3], "enable")
					helpers.assert_eq(args[4], KEYLAYOUT_PATH)
					helpers.assert_eq(tonumber(args[5]), 9,
						"the nested supervisor must finish before the outer owned deadline")
				end,
			},
			{
				label = "disable",
				executable = helpers.HEALTHY_PYTHON,
				invoke = function(IS, done)
					return IS.disable_keylayout_source_async(KL_NAME, "Ergopti+", done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "-c")
					helpers.assert_eq(args[3], "disable")
					helpers.assert_eq(args[4], KL_NAME)
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
				stdout = "0\n",
				invoke = function(IS, done)
					return IS.set_input_source_async(LOCALISED_NAME, KL_NAME, done)
				end,
			},
			{
				label = "enable",
				stdout = "ALREADY_PRESENT\n",
				invoke = function(IS, done)
					return IS.enable_keylayout_source_async(KEYLAYOUT_PATH, "Ergopti+", done)
				end,
			},
			{
				label = "disable",
				stdout = "ABSENT\n",
				invoke = function(IS, done)
					return IS.disable_keylayout_source_async(KL_NAME, "Ergopti+", done)
				end,
			},
			{
				label = "upgrade",
				stdout = "1/1\n",
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
					return IS.enable_keylayout_source_async(KEYLAYOUT_PATH, "Ergopti+", done)
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

		f.tasks[1]:complete(0, "0\n", "")
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

	-- hardening-h-no-rosetta: the editor runs Python; an Apple silicon Mac with
	-- only Intel ones starts nothing and is offered a native one.
	helpers.it("starts no Intel Python to edit the enabled sources and offers a native one", function()
		local f = load_fixture()
		local offers = {}
		package.loaded["ui.python_runtime_offer"] = {
			offer = function(state) offers[#offers + 1] = state; return true end,
		}
		local intel = "\207\250\237\254" .. "\7\0\0\1" .. string.rep("\0", 24)
		package.loaded["adapters.python_interpreter"]._set_deps({
			read_head = function(path)
				if path == helpers.HEALTHY_PYTHON or path == "/usr/local/bin/python3" then return intel end
				return nil
			end,
			realpath = function(path) return path end,
			getenv = function() return nil end,
			select_link_target = function() return nil end,
			process_arch = function() return "arm64" end,
		})
		local terminals = {}
		local accepted = f.IS.enable_keylayout_source_async(KEYLAYOUT_PATH, "Ergopti+", function(ok, _out, reason)
			terminals[#terminals + 1] = { ok = ok, reason = reason }
		end)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(#f.tasks, 0, "no interpreter may start under Rosetta")
		helpers.assert_eq(#terminals, 1)
		helpers.assert_eq(terminals[1].ok, false)
		helpers.assert_eq(terminals[1].reason, "python_unavailable")
		helpers.assert_eq(#offers, 1)
		helpers.assert_eq(offers[1].kind, "python_not_native")
		package.loaded["ui.python_runtime_offer"] = nil
		reset_fixture_modules()
	end)
end)
