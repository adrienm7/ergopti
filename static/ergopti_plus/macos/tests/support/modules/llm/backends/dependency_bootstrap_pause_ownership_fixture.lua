--- tests/support/modules/llm/backends/dependency_bootstrap_pause_ownership_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_dependency_bootstrap_pause_ownership
--- DESCRIPTION:
--- Prelude shared by the test_dependency_bootstrap_pause_ownership_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

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
		-- These existing daemon-ready cases model a native-owned source.
		resolve = function() return "/fixture/ollama", nil, "native_managed" end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		ensure_running = function(transaction)
			fixture.daemon_calls = fixture.daemon_calls + 1
			if options.defer_daemon_ready == true then
				fixture.daemon_transaction = transaction
				return true
			end
			if options.daemon_start_throw == true then error("daemon start exploded") end
			local committed = options.daemon_start_result
			if committed == nil then committed = true end
			fixture.daemon_live = committed == true
			if options.pause_on_daemon_start == true then
				fixture.pause_on_daemon_start_result = fixture.control.pause_all()
			end
			-- A committed start is acceptance only. Publish the controlled READY
			-- observation through the same captured authorized transaction.
			if committed == true and type(transaction) == "table"
				and type(transaction.is_authorized) == "function"
				and transaction.is_authorized() == true
				and type(transaction.on_settled) == "function" then
				transaction.on_settled(true)
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
		is_active = function()
			local active = fixture.ui_active
			if fixture.active_query_hook then fixture.active_query_hook() end
			return active
		end,
		session_id = function()
			local session = fixture.ui_session
			if fixture.session_query_hook then fixture.session_query_hook() end
			return session
		end,
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
	fixture.check_impl = checker.check_and_install_deps
	if options.backend == "mlx" then
		-- The MLX script only ever runs for a selected, absent runtime: model
		-- that state so these cases keep exercising the script's pause owner.
		checker.runtime_installed = function() return false, "/fixture/venv/bin/python" end
		local check = checker.check_and_install_deps
		checker.check_and_install_deps = function(...)
			helpers.assert_true(set_upvalue(check, "_install_granted", true),
				"the MLX bootstrap must keep its selection grant")
			return check(...)
		end
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
		package.loaded["modules.keystats"] = {
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
		function control.get_pause_epoch()
			local epoch = fixture.epoch
			if fixture.epoch_query_hook then fixture.epoch_query_hook() end
			return epoch
		end
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

return {
	get_upvalue = get_upvalue,
	load_fixture = load_fixture,
	set_upvalue = set_upvalue,
}
