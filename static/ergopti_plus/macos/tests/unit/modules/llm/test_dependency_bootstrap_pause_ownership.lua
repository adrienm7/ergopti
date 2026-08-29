--- tests/unit/modules/llm/test_dependency_bootstrap_pause_ownership.lua

--- Behavioral regression for HS-012 dependency bootstrap ownership. The real
--- ScriptControl, TimerScheduler, and TaskLifecycle run over faithful native
--- doubles; the class-wide inventory matrix separately drives both identities
--- through false/nil/throw rollback settlement.

local helpers = require("tests.helpers")

local function set_upvalue(fn, name, value)
	for index = 1, 80 do
		local upvalue_name = debug.getupvalue(fn, index)
		if upvalue_name == nil then return false end
		if upvalue_name == name then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
end

local function get_upvalue(fn, name)
	for index = 1, 80 do
		local upvalue_name, value = debug.getupvalue(fn, index)
		if upvalue_name == nil then return nil end
		if upvalue_name == name then return value end
	end
	return nil
end

local function load_fixture(options)
	options = options or {}
	local fixture = {
		paused = false,
		transition = false,
		epoch = 0,
		tasks = {},
		timers = {},
		ui_calls = 0,
		ui_active = false,
		ui_session = 0,
		ui_hide_calls = 0,
		daemon_calls = 0,
		daemon_live = false,
		start_mode = options.start_mode or "true",
		terminate_mode = options.terminate_mode or "pending",
		timer_start_mode = options.timer_start_mode or "true",
		timer_stop_mode = options.timer_stop_mode or "true",
		pty_create_calls = 0,
		pty_remove_calls = 0,
	}

	local function interrupt_preflight(stage)
		if options.stale_preflight_stage ~= stage
			or fixture.preflight_pause_triggered == true then return end
		fixture.preflight_pause_triggered = true
		fixture.epoch = fixture.epoch + 1
		fixture.transition = true
		fixture.preflight_pause_result = fixture.owner.pause()
	end

	local timer_api = {}
	function timer_api.new(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
		}
		function timer:start()
			self.start_calls = self.start_calls + 1
			self.running_state = true
			if type(fixture.timer_start_hook) == "function" then
				fixture.timer_start_hook(self)
			end
			local mode = fixture.timer_start_mode
			if mode == "sync" then self.callback(); return self end
			if mode == "throw" then error("timer start exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			local mode = fixture.timer_stop_mode
			if mode == "throw" then error("timer stop exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire()
			if self.running_state then self.callback() end
		end
		fixture.timers[#fixture.timers + 1] = timer
		return timer
	end

	local task_api = {}
	function task_api.new(_executable, completion, streaming, args)
		local task = {
			completion = completion,
			streaming = streaming,
			args = args,
			started = false,
			start_calls = 0,
			terminate_calls = 0,
		}
		function task:start()
			self.start_calls = self.start_calls + 1
			self.started = true
			local mode = fixture.start_mode
			if mode:find("^sync_", 1, false) then
				self.completion(0, "", "")
				mode = mode:gsub("^sync_", "")
			end
			if mode == "throw" then error("task start exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return self
		end
		function task:terminate()
			self.terminate_calls = self.terminate_calls + 1
			local mode = fixture.terminate_mode
			if mode:find("^sync_", 1, false) then
				self.completion(143, "", "terminated")
				mode = mode:gsub("^sync_", "")
			end
			if mode == "throw" then error("task terminate exploded") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return self
		end
		function task:complete(code, stdout, stderr)
			return self.completion(code or 0, stdout or "", stderr or "")
		end
		function task:chunk(stdout, stderr)
			return self.streaming(self, stdout or "", stderr or "")
		end
		fixture.tasks[#fixture.tasks + 1] = task
		return task
	end

	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.task_lifecycle"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.llm.ollama_binary"] = {
		resolve = function() return "/fixture/ollama", nil, true end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		ensure_running = function()
			fixture.daemon_calls = fixture.daemon_calls + 1
			if options.daemon_start_throw == true then error("daemon start exploded") end
			local committed = options.daemon_start_result
			if committed == nil then committed = true end
			fixture.daemon_live = committed == true
			if options.pause_on_daemon_start == true then
				fixture.pause_on_daemon_start_result = fixture.control.pause_all()
			end
			return committed
		end,
		pause_warmup = function()
			fixture.daemon_live = false
			return true
		end,
		resume_warmup = function() return true end,
	}
	package.loaded["modules.llm.api_common"] = {
		protected_call = function(callback, _, ...)
			if type(callback) == "function" then return callback(...) end
			return true
		end,
	}
	package.loaded["ui.download_window"] = {
		is_active = function() return fixture.ui_active end,
		session_id = function() return fixture.ui_session end,
		show = function()
			fixture.ui_calls = fixture.ui_calls + 1
			fixture.ui_active = true
			fixture.ui_session = fixture.ui_session + 1
		end,
		hide = function()
			fixture.ui_calls = fixture.ui_calls + 1
			fixture.ui_hide_calls = fixture.ui_hide_calls + 1
			fixture.ui_active = false
		end,
		set_step = function() fixture.ui_calls = fixture.ui_calls + 1 end,
		set_detail = function() fixture.ui_calls = fixture.ui_calls + 1 end,
		set_progress = function() fixture.ui_calls = fixture.ui_calls + 1 end,
		set_error = function() fixture.ui_calls = fixture.ui_calls + 1 end,
		append_log = function() fixture.ui_calls = fixture.ui_calls + 1 end,
	}

	local checker_name = options.backend == "mlx"
		and "modules.llm.mlx_deps_checker"
		or "modules.llm.ollama_deps_checker"
	if options.backend == "mlx" then
		package.loaded["infra.paths"] = {
			find_from_configdir = function()
				return "/repo/modules/llm/ensure-mlx-deps.sh"
			end,
		}
		package.loaded["modules.llm.pty_process_group"] = {
			create = function()
				fixture.pty_create_calls = fixture.pty_create_calls + 1
				interrupt_preflight("pty")
				return "/tmp/fixture-pty-wrapper.py"
			end,
			remove = function()
				fixture.pty_remove_calls = fixture.pty_remove_calls + 1
				return true
			end,
		}
	end
	local checker = helpers.load_with_stubs(checker_name, {
		fs = { attributes = function() return "file" end },
		timer = timer_api,
		task = task_api,
	})
	if options.backend == "mlx" and options.stale_preflight_stage == "path" then
		helpers.assert_true(set_upvalue(checker.check_and_install_deps,
			"resolve_bootstrap_script_path", function()
				interrupt_preflight("path")
				return "/repo/modules/llm/ensure-mlx-deps.sh"
			end))
	elseif options.backend ~= "mlx" then
		helpers.assert_true(set_upvalue(checker.check_and_install_deps,
			"resolve_project_root", function() return "/repo" end))
	end

	local control
	if options.real_script_control == true then
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.keycodes"] = {
			F13_KARABINER_RETURN = 106,
			F14_KARABINER_BACKSPACE = 107,
			F15_KARABINER_ESCAPE = 108,
			BACKSPACE = 51,
			RETURN = 36,
			ESCAPE = 53,
		}
		package.loaded["adapters.event_provenance"] = {}
		local admission_fence = nil
		package.loaded["adapters.synthetic_input"] = {
			when_idle = function(callback) callback(); return true end,
			acquire_admission_fence = function()
				if admission_fence ~= nil then return nil end
				admission_fence = {}
				return admission_fence
			end,
			release_admission_fence = function(token)
				if token ~= admission_fence then return false end
				admission_fence = nil
				return true
			end,
			admission_open = function() return admission_fence == nil end,
			defer_after_callback = function(_, callback)
				return callback() == true
			end,
		}
		package.loaded["adapters.key_state"] = {
			is_right_altgr_held = function() return false end,
			describe_held_modifiers = function() return "(none)" end,
		}
		package.loaded["modules.gestures.engine"] = {}
		package.loaded["modules.gestures.actions"] = {
			SG_NAMES = {}, AX_NAMES = {},
			get_label = function(value) return value end,
			execute_single = function() return true end,
		}
		for _, module_name in ipairs({
			"modules.llm", "modules.llm.api_mlx",
			"modules.llm.warmup_controller", "modules.llm.api_remote",
		}) do
			package.loaded[module_name] = {
				pause_warmup = function() return true end,
				resume_warmup = function() return true end,
			}
		end
		package.loaded["ui.wpm.wpm_menubar"] = { is_running = function() return false end }
		package.loaded["ui.wpm.wpm_widget"] = { is_running = function() return false end }
		package.loaded["platform.remap.onboarding"] = {
			stop = function() return true end,
		}
		package.loaded["ui.tooltip"] = {
			hide_forced = function() return true end,
		}
		package.loaded["modules.keylogger"] = {
			resync_context = function() return true end,
			log_shortcut = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = nil
		control = require("modules.shortcuts.script_control")
		helpers.assert_true(control.start({
			pause_processing = function() return true end,
			resume_processing = function() return true end,
			reset_predictions = function() return true end,
			reset_predictions_for_pause = function() return true end,
		}, {
			is_bindings_started = function() return false end,
			pause_bindings = function() return true end,
			resume_bindings = function() return true end,
			release_bindings_pause_claim = function() return true end,
		}, {
			is_enabled = function() return false end,
			suspend = function() return true end,
			resume = function() return true end,
		}))
	else
		control = {}
		function control.is_paused() return fixture.paused end
		function control.is_pause_transition_pending() return fixture.transition end
		function control.get_pause_epoch() return fixture.epoch end
		function control.register_pause_owner(name, owner)
			fixture.owner_name = name
			fixture.owner = owner
			return true
		end
	end
	helpers.assert_true(checker.configure_pause_owner(control))
	fixture.checker = checker
	fixture.control = control
	return fixture
end

helpers.describe("HS-012 dependency bootstrap native ownership", function()
	helpers.it("registers actual checker admission with real ScriptControl", function()
		local fixture = load_fixture({ real_script_control = true })
		helpers.assert_true(fixture.control.pause_all())
		helpers.assert_true(fixture.control.is_paused())
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_true(fixture.control.resume_all())
		helpers.assert_true(fixture.control.stop())
	end)

	helpers.it("fails admission closed throughout PAUSED and transitions", function()
		local fixture = load_fixture()
		fixture.paused = true
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		fixture.paused = false
		fixture.transition = true
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(#fixture.timers, 0)
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_eq(fixture.checker.get_state(), "pending")
	end)

	helpers.it("rejects cached-state mutation while PAUSED", function()
		local fixture = load_fixture({
			start_mode = "false",
			terminate_mode = "sync_true",
		})
		helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
		fixture.paused = true
		helpers.assert_eq(fixture.checker.reset_bootstrap_state(), false)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
	end)

	helpers.it("never writes into a progress session owned by another operation", function()
		local fixture = load_fixture()
		fixture.ui_active = true
		fixture.ui_session = 41
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "installer detail")
		fixture.tasks[1]:complete(1, "", "foreign-session failure")
		helpers.assert_eq(fixture.ui_calls, 0)
		helpers.assert_eq(fixture.checker.get_state(), "failed")
	end)

	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutated task after start " .. start_mode, function()
			local fixture = load_fixture({
				start_mode = start_mode,
				terminate_mode = "false",
			})
			helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_true(fixture.tasks[1].started,
				"the faithful start double mutates before refusing")
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1)
			fixture.transition = true
			helpers.assert_eq(fixture.owner.pause(), false,
				"PAUSED cannot publish while the exact task has no terminal callback")
			fixture.tasks[1]:complete(143, "", "late")
			fixture.tasks[1]:complete(0, "OLLAMA_INSTALLING", "duplicate")
			helpers.assert_eq(fixture.daemon_calls, 0)
			helpers.assert_eq(fixture.ui_calls, 0)
			helpers.assert_true(fixture.owner.pause())
		end)
	end

	for _, terminate_mode in ipairs({ "false", "nil", "throw", "pending" }) do
		helpers.it("waits for exact completion after terminate " .. terminate_mode, function()
			local fixture = load_fixture({ terminate_mode = terminate_mode })
			helpers.assert_true(fixture.checker.check_and_install_deps())
			fixture.epoch = 1
			fixture.transition = true
			helpers.assert_eq(fixture.owner.pause(), false)
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1)
			fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "late stream")
			fixture.tasks[1]:complete(143, "", "late completion")
			fixture.tasks[1]:complete(0, "OLLAMA_READY", "duplicate")
			helpers.assert_eq(fixture.daemon_calls, 0)
			helpers.assert_eq(fixture.ui_calls, 0)
			helpers.assert_true(fixture.owner.pause())
		end)
	end

	helpers.it("replays only the committed task after exact RESUMED epoch", function()
		local fixture = load_fixture({ terminate_mode = "pending" })
		helpers.assert_true(fixture.checker.check_and_install_deps())
		local old_task = fixture.tasks[1]
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_eq(fixture.owner.pause(), false)
		old_task:complete(143, "", "stopped")
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false

		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 2)
		old_task:complete(0, "OLLAMA_INSTALLING", "duplicate")
		helpers.assert_eq(fixture.daemon_calls, 0)
		fixture.tasks[2]:complete(0, "", "")
		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.checker.get_state(), "ready")
	end)

	helpers.it("rejects a resume-stage callback from a different epoch", function()
		local fixture = load_fixture({ terminate_mode = "sync_true" })
		local controller = get_upvalue(fixture.checker.configure_pause_owner,
			"_pause_controller")
		helpers.assert_not_nil(controller,
			"the real checker must retain its production pause controller")
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		fixture.epoch = 3
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1)
		helpers.assert_eq(controller.current_for_test(), nil,
			"an epoch-lost replay must terminalize its exact token")
		helpers.assert_eq(fixture.checker.get_state(), "failed")
		local timer_count = #fixture.timers
		helpers.assert_true(fixture.owner.resume())
		helpers.assert_eq(#fixture.timers, timer_count,
			"an epoch-lost replay must not require another global resume edge")
	end)

	helpers.it("replays an owned auto-hide timer without relaunching its backend task", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:chunk("OLLAMA_INSTALLING\n", "")
		fixture.tasks[1]:complete(0, "OLLAMA_INSTALLING\n", "")
		helpers.assert_eq(#fixture.tasks, 1)
		local first_hide = fixture.timers[#fixture.timers]
		helpers.assert_eq(first_hide.delay, 1.5)

		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		helpers.assert_eq(first_hide.running_state, false)
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1,
			"hide replay must remain backend-local timer work")
		local replayed_hide = fixture.timers[#fixture.timers]
		helpers.assert_eq(replayed_hide.delay, 1.5)
		helpers.assert_true(replayed_hide ~= first_hide)
	end)

	helpers.it("retains the exact initial timer when start rollback refuses", function()
		local fixture = load_fixture({
			timer_start_mode = "false",
			timer_stop_mode = "false",
		})
		helpers.assert_eq(fixture.checker.schedule_initial_check(), false)
		helpers.assert_eq(#fixture.timers, 1)
		helpers.assert_true(fixture.timers[1].running_state)
		helpers.assert_eq(#fixture.tasks, 0)
		helpers.assert_eq(fixture.owner.pause(), false)
		fixture.timer_stop_mode = "true"
		helpers.assert_true(fixture.owner.pause())
		helpers.assert_eq(fixture.timers[1].running_state, false)
	end)

	for _, backend in ipairs({ "ollama", "mlx" }) do
		for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(backend .. " defers a fired one-shot after native stop "
				.. stop_mode, function()
				local fixture = load_fixture({
					backend = backend,
					timer_stop_mode = stop_mode,
				})
				helpers.assert_true(fixture.checker.schedule_initial_check())
				local initial_timer = fixture.timers[1]
				initial_timer:fire()
				helpers.assert_eq(#fixture.tasks, 0,
					"business cannot start while the fired native timer remains live")
				helpers.assert_true(initial_timer.running_state)
				local stop_calls = initial_timer.stop_calls
				initial_timer.callback()
				helpers.assert_eq(#fixture.tasks, 0,
					"duplicate native delivery must remain cleanup-only")
				helpers.assert_true(initial_timer.stop_calls > stop_calls,
					"duplicate delivery must retry the same native handle")

				fixture.timer_stop_mode = "true"
				helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
				helpers.assert_eq(initial_timer.running_state, false)
				helpers.assert_eq(#fixture.tasks, 1,
					"exact settlement releases one authorized bootstrap delivery")
				initial_timer.callback()
				helpers.assert_eq(#fixture.tasks, 1,
					"late delivery cannot launch a sibling task")
			end)
		end
	end

	helpers.it("replays only after a fired resume timer exactly settles", function()
		local fixture = load_fixture({ terminate_mode = "sync_true" })
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.epoch = 1
		fixture.transition = true
		helpers.assert_true(fixture.owner.pause())
		fixture.paused = true
		fixture.transition = false
		fixture.epoch = 2
		fixture.transition = true
		helpers.assert_true(fixture.owner.resume())
		local resume_timer = fixture.timers[#fixture.timers]
		fixture.paused = false
		fixture.transition = false
		fixture.timer_stop_mode = "false"
		resume_timer:fire()
		helpers.assert_eq(#fixture.tasks, 1,
			"a live resume timer cannot publish replay")
		fixture.timer_stop_mode = "true"
		helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
		helpers.assert_eq(#fixture.tasks, 2)
		fixture.tasks[2]:complete(0, "", "")
	end)

	for _, backend in ipairs({ "ollama", "mlx" }) do
		for _, stop_mode in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it(backend .. " publishes timer acquisition before reentrant PAUSE with stop "
				.. stop_mode, function()
				local fixture = load_fixture({
					backend = backend,
					timer_stop_mode = stop_mode,
				})
				fixture.timer_start_hook = function()
					fixture.timer_start_hook = nil
					fixture.transition = true
					fixture.pause_during_timer_start = fixture.owner.pause()
				end
				helpers.assert_eq(fixture.checker.schedule_initial_check(), false)
				helpers.assert_eq(fixture.pause_during_timer_start, false)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(#fixture.timers, 1)
				if stop_mode == "true" then
					helpers.assert_eq(fixture.timers[1].running_state, false)
				else
					helpers.assert_true(fixture.timers[1].running_state)
					fixture.timer_stop_mode = "true"
					helpers.assert_true(fixture.owner.pause())
					helpers.assert_eq(fixture.timers[1].running_state, false)
				end
			end)
		end
	end

	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " rolls back a resume stage interrupted inside timer start",
			function()
				local fixture = load_fixture({
					backend = backend,
					terminate_mode = "sync_true",
				})
				helpers.assert_true(fixture.checker.check_and_install_deps())
				fixture.epoch = 1
				fixture.transition = true
				helpers.assert_true(fixture.owner.pause())
				fixture.paused = true
				fixture.transition = false
				fixture.epoch = 2
				fixture.transition = true
				fixture.timer_start_hook = function()
					fixture.timer_start_hook = nil
					fixture.pause_during_resume_start = fixture.owner.pause()
				end
				helpers.assert_eq(fixture.owner.resume(), false)
				helpers.assert_eq(fixture.pause_during_resume_start, false)
				helpers.assert_eq(#fixture.tasks, 1)
				local resume_timer = fixture.timers[#fixture.timers]
				helpers.assert_eq(resume_timer.running_state, false)
				resume_timer:fire()
				helpers.assert_eq(#fixture.tasks, 1)
			end)
	end
end)

helpers.describe("HS-193 dependency bootstrap replay refusal", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " consumes a committed token after replay refuses", function()
			local fixture = load_fixture({ backend = backend })
			local controller = get_upvalue(fixture.checker.configure_pause_owner,
				"_pause_controller")
			helpers.assert_not_nil(controller,
				"the real checker must retain its production pause controller")
			local completions = {}
			helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end))
			local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
			fixture.tasks[1]:chunk(marker, "")
			fixture.tasks[1]:complete(0, marker, "")
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], true)
			helpers.assert_eq(fixture.checker.get_state(), "ready")

			fixture.epoch = 1
			fixture.transition = true
			helpers.assert_true(fixture.owner.pause())
			fixture.paused = true
			fixture.transition = false
			fixture.epoch = 2
			fixture.transition = true
			helpers.assert_true(fixture.owner.resume())
			local resume_stage = fixture.timers[#fixture.timers]
			fixture.paused = false
			fixture.transition = false
			fixture.timer_start_mode = "false"
			resume_stage:fire()

			helpers.assert_eq(controller.current_for_test(), nil,
				"a replay refusal must produce a terminal token instead of parked intent")
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"auto-hide replay failure must not poison completed dependencies")
			local timer_count = #fixture.timers
			fixture.timer_start_mode = "true"
			helpers.assert_true(fixture.owner.resume())
			helpers.assert_eq(#fixture.timers, timer_count,
				"a consumed replay failure must not require another global resume edge")
		end)
	end
end)

helpers.describe("HS-117 dependency checker callback symmetry", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " queues the shared completion signature exactly once", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			local function record(label)
				return function(ok)
					completions[#completions + 1] = { label = label, ok = ok }
				end
			end

			helpers.assert_true(fixture.checker.check_and_install_deps(record("first")))
			helpers.assert_true(fixture.checker.check_and_install_deps(record("second")))
			helpers.assert_eq(#fixture.tasks, 1,
				"a second waiter must join the live bootstrap, not start a sibling")
			helpers.assert_eq(#completions, 0,
				"dispatch acceptance is not business completion")

			fixture.tasks[1]:complete(0, "", "")

			helpers.assert_eq(#completions, 2)
			helpers.assert_eq(completions[1].label, "first")
			helpers.assert_eq(completions[2].label, "second")
			helpers.assert_eq(completions[1].ok, true)
			helpers.assert_eq(completions[2].ok, true)
		end)

		helpers.it(backend .. " reports terminal bootstrap failure through the shared callback", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end))

			fixture.tasks[1]:complete(1, "", "fixture failure")

			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)
		end)

		helpers.it(backend .. " settles the callback when bootstrap preflight refuses", function()
			local fixture = load_fixture({ backend = backend })
			local resolver_name = backend == "mlx"
				and "resolve_bootstrap_script_path" or "resolve_project_root"
			helpers.assert_true(set_upvalue(fixture.checker.check_and_install_deps,
				resolver_name, function() return nil end))
			local completions = {}

			helpers.assert_eq(fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end), false)

			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)
		end)
	end
end)

helpers.describe("HS-118 dependency bootstrap auto-hide refusal", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " closes its progress session when auto-hide acquisition refuses",
			function()
				local fixture = load_fixture({ backend = backend })
				local completions = {}
				helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
					completions[#completions + 1] = ok
				end))
				local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
				fixture.tasks[1]:chunk(marker, "")
				helpers.assert_true(fixture.ui_active,
					"the real-sync marker must claim the progress surface")

				fixture.timer_start_hook = function(timer)
					if timer.delay ~= 1.5 then return end
					fixture.timer_start_hook = nil
					fixture.timer_start_mode = "false"
					fixture.timer_stop_mode = "false"
				end
				fixture.tasks[1]:complete(0, marker, "")

				helpers.assert_eq(fixture.checker.get_state(), "ready")
				helpers.assert_eq(#completions, 1)
				helpers.assert_eq(completions[1], true)
				helpers.assert_eq(fixture.ui_hide_calls, 1,
					"timer refusal must fall back to closing the exact owned session")
				helpers.assert_eq(fixture.ui_active, false)
				local refused_hide = fixture.timers[#fixture.timers]
				helpers.assert_eq(refused_hide.delay, 1.5)
				helpers.assert_true(refused_hide.running_state,
					"the native timer debt stays owned even though the UI is closed")
			end)

		helpers.it(backend .. " never hides a replacement session after auto-hide refusal",
			function()
				local fixture = load_fixture({ backend = backend })
				helpers.assert_true(fixture.checker.check_and_install_deps())
				local marker = backend == "mlx" and "VENV_SYNC_RAN\n" or "OLLAMA_INSTALLING\n"
				fixture.tasks[1]:chunk(marker, "")
				fixture.timer_start_hook = function(timer)
					if timer.delay ~= 1.5 then return end
					fixture.timer_start_hook = nil
					fixture.ui_session = fixture.ui_session + 1
					fixture.timer_start_mode = "false"
					fixture.timer_stop_mode = "false"
				end

				fixture.tasks[1]:complete(0, marker, "")

				helpers.assert_eq(fixture.checker.get_state(), "ready")
				helpers.assert_eq(fixture.ui_hide_calls, 0,
					"the fallback may close only the session claimed by this checker")
				helpers.assert_true(fixture.ui_active,
					"the replacement operation's progress surface must remain visible")
			end)
	end
end)

helpers.describe("HS-119 Ollama provisioning and daemon verdicts", function()
	helpers.it("keeps dependencies ready when only daemon acquisition refuses", function()
		local fixture = load_fixture({
			backend = "ollama",
			daemon_start_result = false,
		})
		local completions = {}
		helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
			completions[#completions + 1] = ok
		end))

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.checker.get_state(), "ready",
			"successful provisioning must not be poisoned by daemon acquisition")
		helpers.assert_true(fixture.checker.is_ready())
		helpers.assert_eq(fixture.checker.has_failed(), false)
		helpers.assert_eq(fixture.checker.get_failure_message(), nil)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "failed")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_true(fixture.checker.has_daemon_failed())
		helpers.assert_true(type(fixture.checker.get_daemon_failure_message()) == "string"
			and fixture.checker.get_daemon_failure_message() ~= "")
		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1], false,
			"the overall bootstrap callback still reports the unusable daemon")
	end)

	helpers.it("classifies a throwing daemon acquisition in the daemon domain", function()
		local fixture = load_fixture({
			backend = "ollama",
			daemon_start_throw = true,
		})
		local completions = {}
		helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
			completions[#completions + 1] = ok
		end))

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.checker.get_state(), "ready")
		helpers.assert_eq(fixture.checker.has_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "failed")
		helpers.assert_true(fixture.checker.has_daemon_failed())
		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1], false)
	end)

	helpers.it("reports successful provisioning and daemon acquisition independently", function()
		local fixture = load_fixture({ backend = "ollama" })
		helpers.assert_true(fixture.checker.check_and_install_deps())

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.checker.get_state(), "ready")
		helpers.assert_true(fixture.checker.is_ready())
		helpers.assert_eq(fixture.checker.get_failure_message(), nil)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "ready")
		helpers.assert_true(fixture.checker.is_daemon_ready())
		helpers.assert_eq(fixture.checker.has_daemon_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_failure_message(), nil)
	end)

	helpers.it("keeps daemon verdict pending when dependency provisioning fails", function()
		local fixture = load_fixture({ backend = "ollama" })
		helpers.assert_true(fixture.checker.check_and_install_deps())

		fixture.tasks[1]:complete(1, "", "dependency failure")

		helpers.assert_eq(fixture.checker.get_state(), "failed")
		helpers.assert_true(fixture.checker.has_failed())
		helpers.assert_true(type(fixture.checker.get_failure_message()) == "string")
		helpers.assert_eq(fixture.checker.get_daemon_state(), "pending")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_eq(fixture.checker.has_daemon_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_failure_message(), nil)
	end)
end)

helpers.describe("HS-115 pre-commit callback obligations", function()
	for _, stage in ipairs({ "path", "pty" }) do
		helpers.it("settles the registered MLX callback when PAUSE supersedes " .. stage
			.. " preflight", function()
			local fixture = load_fixture({
				backend = "mlx",
				stale_preflight_stage = stage,
			})
			local completions = {}
			local accepted = fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end)

			helpers.assert_eq(accepted, false,
				"a superseded pre-commit intent never claims dispatch")
			helpers.assert_true(fixture.preflight_pause_result,
				"the injected PAUSE must settle before the stale check")
			helpers.assert_eq(#completions, 1,
				"an already registered waiter remains a terminal obligation")
			helpers.assert_eq(completions[1], false)
			helpers.assert_eq(#fixture.tasks, 0,
				"no native child may start after the preflight intent is superseded")
			helpers.assert_eq(fixture.checker.get_state(), "pending")
			if stage == "path" then
				helpers.assert_eq(fixture.pty_create_calls, 0)
			else
				helpers.assert_eq(fixture.pty_create_calls, 1)
				helpers.assert_eq(fixture.pty_remove_calls, 1,
					"the prepared wrapper must be removed before returning")
			end
		end)
	end
end)

helpers.describe("HS-113 dependency bootstrap deadline", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " fails a never-completing bootstrap at the owned deadline", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			local accepted = fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end)

			helpers.assert_true(accepted)
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_eq(#fixture.timers, 1,
				"every committed bootstrap task must own one deadline")
			helpers.assert_eq(fixture.timers[1].delay, 1800,
				"the deadline must use the shared 30-minute bootstrap ceiling")
			helpers.assert_eq(fixture.checker.get_state(), "pending")

			fixture.timers[1]:fire()

			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1,
				"deadline expiry must terminate the exact task once")
			helpers.assert_eq(fixture.checker.get_state(), "failed")
			helpers.assert_true(type(fixture.checker.get_failure_message()) == "string"
				and fixture.checker.get_failure_message() ~= "",
				"deadline expiry must publish a visible failure reason")
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)

			fixture.tasks[1]:complete(143, "", "late timeout settlement")
			helpers.assert_eq(fixture.checker.get_state(), "failed",
				"late native settlement cannot reverse the timeout outcome")
			helpers.assert_eq(#completions, 1)
		end)

		helpers.it(backend .. " cancels its deadline before publishing normal completion", function()
			local fixture = load_fixture({ backend = backend })
			helpers.assert_true(fixture.checker.check_and_install_deps())
			helpers.assert_eq(#fixture.timers, 1)
			local deadline = fixture.timers[1]

			fixture.tasks[1]:complete(0, "", "")

			helpers.assert_eq(deadline.running_state, false)
			helpers.assert_eq(deadline.stop_calls, 1,
				"normal completion must cancel the exact deadline once")
			helpers.assert_eq(fixture.checker.get_state(), "ready")
			deadline.callback()
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 0)
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"a stale deadline callback must remain inert")
		end)

		helpers.it(backend .. " withholds success until deadline cancellation settles", function()
			local fixture = load_fixture({
				backend = backend,
				timer_stop_mode = "false",
			})
			helpers.assert_true(fixture.checker.check_and_install_deps())
			fixture.tasks[1]:complete(0, "", "")
			helpers.assert_eq(fixture.checker.get_state(), "pending",
				"a live deadline can still fire and must fence business success")
			helpers.assert_true(fixture.timers[1].running_state)

			fixture.timer_stop_mode = "true"
			helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"exact timer settlement must resume the retained terminal outcome")
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 0)
		end)

		helpers.it(backend .. " never starts without a committed deadline", function()
			local fixture = load_fixture({
				backend = backend,
				timer_start_mode = "false",
			})
			helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
			helpers.assert_eq(#fixture.tasks, 1,
				"the task may be prepared before deadline acquisition")
			helpers.assert_eq(fixture.tasks[1].start_calls, 0,
				"the native subprocess boundary must remain untouched")
			helpers.assert_eq(fixture.checker.get_state(), "failed")
		end)
	end
end)

helpers.describe("HS-012 dependency-to-daemon pause handoff", function()
	helpers.it("quiesces ApiOllama when PAUSE re-enters its real checker handoff", function()
		local fixture = load_fixture({
			real_script_control = true,
			pause_on_daemon_start = true,
		})
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:complete(0, "", "")
		helpers.assert_true(fixture.pause_on_daemon_start_result)
		helpers.assert_true(fixture.control.is_paused())
		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.daemon_live, false)
		helpers.assert_true(fixture.checker.is_ready(),
			"the completed provisioning verdict survives daemon PAUSE")
		helpers.assert_eq(fixture.checker.get_daemon_state(), "pending")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_true(fixture.control.stop())
	end)
end)

helpers.describe("HS-012 dependency bootstrap backend isolation", function()
	helpers.it("declares two distinct registered child owners", function()
		local mlx_source = helpers.read_driver_source(
			"owner_name = \"mlx_dependency_bootstrap\"")
		local ollama_source = helpers.read_driver_source(
			"owner_name = \"ollama_dependency_bootstrap\"")
		helpers.assert_not_nil(mlx_source)
		helpers.assert_not_nil(ollama_source)
		helpers.assert_true(mlx_source:find("ollama_dependency_bootstrap", 1, true) == nil)
		helpers.assert_true(ollama_source:find("mlx_dependency_bootstrap", 1, true) == nil)
	end)
end)
