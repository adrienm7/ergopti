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
--- Preserve that status across selection and migration before publishing success
--- (tis-osstatus); native worker tests verify the individual Carbon mutations.
--- Discover every replacement before disabling a working legacy source: a
--- predictable missing target must not partially mutate the enabled list.
--- ==============================================================================

local BaseHelpers = require("tests.helpers")
local FIXTURE_MODULES = { "modules.keymap.input_sources", "modules.keymap.layout_install" }
local helpers = setmetatable({}, { __index = BaseHelpers })

--- Registers the original case under its two exact installation-port owners.
--- The parent can retain its captured port only for this case, including errors.
--- @param name string Original regression description.
--- @param body function Original case body and assertions.
function helpers.it(name, body)
	return BaseHelpers.it(name, function()
		return BaseHelpers.with_fresh_modules(FIXTURE_MODULES, body)
	end)
end

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


--- Loads the real parent with an explicitly empty installed-bundle inventory.
--- The standard preload hook survives the loader's intentional cache reset;
--- its exact predecessor is restored even when parent construction raises.
--- @param overrides table Native task, timer and execute boundaries.
--- @return table sources Real input-source controller bound to the inventory port.
local function load_sources_without_installed_bundles(overrides)
	local module_name = "modules.keymap.layout_install"
	local preload = package.preload
	local previous_loader = preload[module_name]
	preload[module_name] = function()
		return {
			highest_installed = function() return nil end,
			version_gt = function() return false end,
			bundle_variants = function() return {} end,
			USER_LAYOUTS_DIR = "/virtual/user-layouts",
			SYSTEM_LAYOUTS_DIR = "/virtual/system-layouts",
		}
	end
	local outcome = table.pack(xpcall(helpers.load_with_stubs, debug.traceback,
		"modules.keymap.input_sources", overrides))
	preload[module_name] = previous_loader
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
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

	local IS = load_sources_without_installed_bundles({
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
		helpers.assert_eq(#f.tasks[1].args, 3)
		helpers.assert_eq(f.tasks[1].args[1], "--select-input-source-by-name")
		helpers.assert_eq(f.tasks[1].args[2], LOCALISED_NAME)
		helpers.assert_eq(f.tasks[1].args[3], KL_NAME)
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

	status_test("(tis-native-selector) resolves the French menu name through one native inventory", function()
		local f = load_fixture()
		local terminal = nil
		hs.keycodes.layouts = function() error("Separate name/ID snapshots cannot prove identity") end
		helpers.assert_eq(f.IS.set_input_source_async("French", "French", function(ok)
			terminal = ok
		end), true)
		helpers.assert_eq(f.tasks[1].args[1], "--select-input-source-by-name")
		helpers.assert_eq(f.tasks[1].args[2], "French")
		helpers.assert_eq(f.tasks[1].args[3], "French")
		f.tasks[1]:complete(0, "0\n", "")
		helpers.assert_eq(terminal, true)
		reset_fixture_modules()
	end)

	status_test("(tis-osstatus) refuses every native migration status without counting success", function()
		for _, operation in ipairs({ "TISDisableInputSource", "TISEnableInputSource", "TISSelectInputSource" }) do
			local f = load_fixture()
			local terminal
			helpers.assert_eq(f.IS.upgrade_active_list_async({ "com.apple.keylayout.ergopti.plus" }, function(ok)
				terminal = ok
			end), true)
			helpers.assert_eq(f.tasks[1].executable, NATIVE_HELPER)
			f.tasks[1]:complete(0, operation .. ":-50\n", "")
			helpers.assert_eq(terminal, false, operation .. " refusal must not become upgrade success")
			reset_fixture_modules()
		end
	end)

	status_test("(tis-partial-upgrade) requires every requested replacement before reporting success", function()
		local cases = {
			{ requested = 2, stdout = "1/1\n", ok = false },
			{ requested = 2, stdout = "1/2\n", ok = true },
			{ requested = 1, stdout = "1/2\n", ok = false },
			{ requested = 2, stdout = "2/2\n", ok = true },
			{ requested = 2, stdout = "0/0\n", ok = false },
			{ requested = 2, stdout = "1, /, 2\n", ok = false },
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

	status_test("(tis-target-preflight) transfers every replacement in one immutable native transaction", function()
		local f = load_fixture()
		local entries = { "com.apple.keylayout.ergopti.plus", "com.apple.keylayout.ergopti.ansi" }
		helpers.assert_eq(f.IS.upgrade_active_list_async(entries, function() end), true)
		entries[1], entries[2] = "changed", nil
		local args = f.tasks[1].args
		helpers.assert_eq(f.tasks[1].executable, NATIVE_HELPER)
		helpers.assert_eq(#f.tasks, 1, "all replacements belong to one native preflight")
		helpers.assert_eq(#args, 5)
		helpers.assert_eq(args[1], "--upgrade-input-sources")
		helpers.assert_eq(args[2], "com.apple.keylayout.ergopti.plus")
		helpers.assert_eq(args[3], "com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(args[4], "com.apple.keylayout.ergopti.ansi")
		helpers.assert_eq(args[5], "com.apple.keyboardlayout.ergopti.ansi")
		f.tasks[1]:complete(0, "2/2\n", "")
		reset_fixture_modules()
	end)

	status_test("(tis-native-upgrade) refuses an unavailable helper before any native transaction", function()
		local f = load_fixture({ helper_unavailable = true })
		local terminal
		helpers.assert_eq(f.IS.upgrade_active_list_async({ "com.apple.keylayout.ergopti.plus" },
			function(ok, _, reason) terminal = { ok = ok, reason = reason } end), false)
		helpers.assert_eq(#f.tasks, 0)
		helpers.assert_eq(#f.timers, 0)
		helpers.assert_eq(terminal.ok, false)
		helpers.assert_eq(terminal.reason, "helper_unavailable")
		reset_fixture_modules()
	end)

	status_test("(tis-native-upgrade) rejects incomplete request tables before any child starts", function()
		for _, entries in ipairs({
			{ [1] = "com.apple.keylayout.ergopti.plus", [3] = "com.apple.keylayout.ergopti.ansi" },
			{ "com.apple.keylayout.ergopti.plus", foreign = "com.apple.keylayout.ergopti.ansi" },
			{ "com.apple.keylayout.ergopti.plus", true },
		}) do
			local f = load_fixture()
			local terminal
			helpers.assert_eq(f.IS.upgrade_active_list_async(entries,
				function(ok, _, reason) terminal = { ok = ok, reason = reason } end), false)
			helpers.assert_eq(#f.tasks, 0)
			helpers.assert_eq(#f.timers, 0)
			helpers.assert_eq(terminal.ok, false)
			helpers.assert_eq(terminal.reason, "invalid_entries")
			reset_fixture_modules()
		end
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
					helpers.assert_eq(args[1], "--select-input-source-by-name")
					helpers.assert_eq(args[2], LOCALISED_NAME)
					helpers.assert_eq(args[3], KL_NAME)
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
				executable = NATIVE_HELPER,
				invoke = function(IS, done)
					return IS.upgrade_active_list_async({ "Ergopti_v2_2_1_plus" }, done)
				end,
				assert_args = function(args)
					helpers.assert_eq(args[1], "--upgrade-input-sources")
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


helpers.describe("input-source mutations: a terminal callback may start the next one", function()
	-- The composer's failed enable ran its rollback disable from its own terminal
	-- callback, which the slot still owned, so the rollback was refused "busy"
	-- (field session 2026-10-27). The slot is released before the terminal.
	status_test("(tis-slot-release) admits a mutation started from the previous terminal callback", function()
		local f = load_fixture()
		local second_accepted, second_reason = nil, nil
		helpers.assert_eq(f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME, function()
			second_accepted = f.IS.set_input_source_async(LOCALISED_NAME, KL_NAME, function(_, _, reason)
				second_reason = reason
			end)
		end), true)
		f.tasks[1]:complete(0, "-50\n", "")
		helpers.assert_eq(second_accepted, true, "the follow-up mutation must not be refused as busy")
		helpers.assert_true(second_reason ~= "busy", "the follow-up mutation must not be refused as busy")
		f.tasks[2]:complete(0, "0\n", "")
		reset_fixture_modules()
	end)
end)


helpers.describe("input-source enable: the preference is not the live state (composer-macos26)", function()
	-- The editor ended with `launchctl kickstart -k user/<uid>/com.apple.SystemUIServer`,
	-- a service that is not in the user domain: launchctl answered 113 after every
	-- successful write, the script exited 1 and every enable read "process_failed"
	-- (field runs 2026-10-27, L52). The script must end on its own write.
	helpers.it("ends the enabled-list editor on its own write, with no agent restart", function()
		local source = helpers.read_driver_source("local ENABLED_LIST_SCRIPT = [[")
		helpers.assert_not_nil(source, "the editor script's owner is found")
		local script = source:match("local ENABLED_LIST_SCRIPT = %[%[(.-)%]%]")
		helpers.assert_not_nil(script, "the editor script is found")
		helpers.assert_true(script:find("launchctl", 1, true) == nil, "the editor restarts no agent")
		helpers.assert_true(script:find('run_child(["defaults", "import", DOMAIN, tmp])', 1, true) ~= nil)
		helpers.assert_true(script:find('os.unlink(tmp)\n\nprint("OK")', 1, true) ~= nil,
			"OK follows the import directly")
	end)

	helpers.it("reads a layout as on only from the live list", function()
		local f = load_fixture()
		local live = { names = { "French", "Composer Check", f.IS.format_ergopti_display(KL_NAME) },
			ids = { "com.apple.keylayout.French", "org.unknown.keylayout.Loose Name" } }
		helpers.assert_eq(f.IS.is_live_enabled("Composer Check", live), true)
		helpers.assert_eq(f.IS.is_live_enabled("Loose Name", live), true, "a loose layout's id carries its name")
		helpers.assert_eq(f.IS.is_live_enabled(KL_NAME, live), true, "an Ergopti layout is listed by its display")
		helpers.assert_eq(f.IS.is_live_enabled("Ergo-L", live), false)
		local unreadable, reason = f.IS.is_live_enabled("Ergo-L", false)
		helpers.assert_nil(unreadable)
		helpers.assert_eq(reason, "live_state_unreadable")
		reset_fixture_modules()
	end)
end)


helpers.describe("input-source confirm: a fresh process reads the state (composer-macos26)", function()
	status_test("passes the canonical settle delay to every refresh child (input-source-refresh-timing)", function()
		local previous_timings = require("infra.timings")
		local previous_loader = package.preload["infra.timings"]
		local original_sec = previous_timings.sec
		local injected, reads = 0.137, 0
		local deadline = original_sec("ui", "input_source_operation_timeout_ms")
		local timing_port = setmetatable({}, { __index = previous_timings })
		timing_port.sec = function(section, key)
			if section == "ui" and key == "input_source_reselect_settle_ms" then
				reads = reads + 1
				return injected
			end
			return original_sec(section, key)
		end
		local ok, detail = xpcall(function()
			-- The normal loader clears timings; the preload owns this one injection
			package.preload["infra.timings"] = function() return timing_port end
			local f = load_fixture()
			package.preload["infra.timings"] = previous_loader
			local answers = 0
			for _, refresh in ipairs({ true, false }) do
				helpers.assert_eq(f.IS.confirm_source_async("Composer Check", { refresh = refresh }, function(confirmed)
					helpers.assert_eq(confirmed, true)
					answers = answers + 1
				end), true)
				local task = f.tasks[#f.tasks]
				helpers.assert_eq(task.args[6], tostring(injected),
					"the real child argv must carry the injected timing, not a Python default")
				helpers.assert_eq(#task.args, 6)
				task:complete(0, '{"listed":true,"enabled":true}', "")
				injected = 0.291
			end
			helpers.assert_eq(reads, 2, "read the current shared duration once for each child")
			helpers.assert_eq(answers, 2)
			helpers.assert_eq(f.timers[1].delay, deadline, "the overall operation deadline is independent")
		end, debug.traceback)
		package.preload["infra.timings"] = previous_loader
		package.loaded["infra.timings"] = previous_timings
		reset_fixture_modules()
		if not ok then error(detail, 0) end
	end)

	-- Probe v5 (P5, P9): after the preference write, the writing process and
	-- Hammerspoon keep a stale list (enabled=false, select -50) while a process
	-- started after the write sees the layout on and selects it.
	helpers.it("reads, registers and refreshes through its own owned child", function()
		local f = load_fixture()
		local answers = {}
		helpers.assert_eq(f.IS.confirm_source_async("Composer Check", { register_path = "/u/composed.keylayout", refresh = true },
			function(ok, state, reason) answers[#answers + 1] = { ok = ok, state = state, reason = reason } end), true)
		local args = f.tasks[1].args
		helpers.assert_eq(f.tasks[1].executable, helpers.HEALTHY_PYTHON)
		helpers.assert_eq(args[1], "-c")
		helpers.assert_true(args[2]:find("TISRegisterInputSource", 1, true) ~= nil)
		helpers.assert_eq(args[3], "Composer Check")
		helpers.assert_eq(args[4], "/u/composed.keylayout")
		helpers.assert_eq(args[5], "refresh")
		helpers.assert_eq(args[6], tostring(require("infra.timings").sec("ui", "input_source_reselect_settle_ms")),
			"the refresh pause comes from the timing registry")
		f.tasks[1]:complete(0, '{"listed": true, "enabled": true, "selected": false, "register": 0, "refreshed": null}\n', "")
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].ok, true)
		helpers.assert_eq(answers[1].state.enabled, true)
		reset_fixture_modules()
	end)

	helpers.it("refuses output that is not the child's JSON state", function()
		for _, case in ipairs({ { 0, "OK\n" }, { 0, '{"enabled": true}' }, { 1, '{"listed": true}' } }) do
			local f = load_fixture()
			local answer
			f.IS.confirm_source_async("Composer Check", {}, function(ok, _state, reason) answer = { ok = ok, reason = reason } end)
			f.tasks[1]:complete(case[1], case[2], "")
			helpers.assert_eq(answer.ok, false)
			helpers.assert_true(answer.reason == "invalid_output" or answer.reason == "process_failed", tostring(answer.reason))
			reset_fixture_modules()
		end
	end)
end)


helpers.describe("input-source confirm: fresh reads until the write applies (composer-macos26)", function()
	-- Field run 2026-10-28 12:51: the composed layout was read 140 ms after the
	-- preference write and found off; probe v5 read it seconds later and found it on.
	local OFF = '{"listed": true, "enabled": false, "selected": false, "register": 0, "enable": 0, "refreshed": null}\n'
	local ON = '{"listed": true, "enabled": true, "selected": false, "register": null, "enable": null, "refreshed": null}\n'

	helpers.it("enables from the first child, then reads again from a new child after a delay", function()
		local f = load_fixture()
		local answers = {}
		helpers.assert_eq(f.IS.confirm_enabled_async("Composer Check", { register_path = "/u/composed.keylayout" },
			function(ok, state, reason) answers[#answers + 1] = { ok = ok, state = state, reason = reason } end), true)
		helpers.assert_eq(f.tasks[1].args[4], "/u/composed.keylayout")
		helpers.assert_eq(f.tasks[1].args[5], "enable", "the first child also asks TIS to enable it")
		f.tasks[1]:complete(0, OFF, "")
		helpers.assert_eq(#answers, 0, "an off read inside the window is not the answer")
		helpers.assert_eq(#f.tasks, 1, "the next read waits for its delay")
		f.timers[#f.timers]:fire()
		helpers.assert_eq(#f.tasks, 2, "a new fresh child reads again")
		helpers.assert_eq(f.tasks[2].args[4], "", "the later reads only read")
		helpers.assert_eq(f.tasks[2].args[5], "")
		f.tasks[2]:complete(0, ON, "")
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].ok, true)
		helpers.assert_eq(answers[1].state.enabled, true)
		reset_fixture_modules()
	end)

	helpers.it("answers the last off read once the bounded window is spent", function()
		local f = load_fixture()
		local answers = {}
		f.IS.confirm_enabled_async("Composer Check", {}, function(ok, state) answers[#answers + 1] = { ok = ok, state = state } end)
		local reads = 0
		while #answers == 0 do
			reads = reads + 1
			helpers.assert_true(reads <= 10, "the window must end")
			f.tasks[#f.tasks]:complete(0, OFF, "")
			if #answers == 0 then f.timers[#f.timers]:fire() end
		end
		helpers.assert_eq(reads, 5, "500 ms doubling within 8 s: reads at 0, 0.5, 1.5, 3.5 and 7.5 s")
		helpers.assert_eq(answers[1].ok, true)
		helpers.assert_eq(answers[1].state.enabled, false)
		reset_fixture_modules()
	end)
end)

helpers.describe("input-source refresh: one admitted settling delay", function()
	status_test("forwards the timing reader's value to the actual confirmation program (input-source-refresh-delay)", function()
		BaseHelpers.provide_timings()
		local real = require("infra.timings")
		local previous_loader = package.preload["infra.timings"]
		local previous_loaded = package.loaded["infra.timings"]
		local admitted, reads = {}, 0
		for key, value in pairs(real) do admitted[key] = value end
		admitted.sec = function(section, key)
			if section == "ui" and key == "input_source_reselect_settle_ms" then
				reads = reads + 1
				return 0.417
			end
			return real.sec(section, key)
		end
		local ok, failure = xpcall(function()
			package.preload["infra.timings"] = function() return admitted end
			package.loaded["infra.timings"] = nil
			local f, calls = load_fixture(), 0
			helpers.assert_eq(f.IS.confirm_source_async("Composer Check", { refresh = true }, function()
				calls = calls + 1
			end), true)
			local args = f.tasks[1].args
			helpers.assert_eq(args[1], "-c")
			helpers.assert_eq(args[3], "Composer Check")
			helpers.assert_eq(args[5], "refresh")
			helpers.assert_eq(args[6], "0.417", "the private worker receives the admitted timing, not a copied default")
			helpers.assert_true(reads > 0, "the genuine timing interface must be consulted")
			f.tasks[1]:complete(0, '{"listed":true,"enabled":true,"select_capable":true,"selected":false}', "")
			helpers.assert_eq(calls, 1)
		end, debug.traceback)
		package.preload["infra.timings"] = previous_loader
		package.loaded["infra.timings"] = previous_loaded
		reset_fixture_modules()
		if not ok then error(failure, 0) end
	end)
end)
