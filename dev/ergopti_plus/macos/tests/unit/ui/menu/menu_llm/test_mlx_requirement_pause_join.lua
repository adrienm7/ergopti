--- tests/unit/ui/menu/menu_llm/test_mlx_requirement_pause_join.lua

--- ==============================================================================
--- MODULE: MLX Requirement Pause-Join Regression
--- DESCRIPTION:
--- Composes the real ScriptControl transaction, ModelSwitcher or Startup
--- owner, TaskLifecycle adapter, and MLX requirements manager around one exact
--- native import-probe task.
---
--- FEATURES & RATIONALE:
--- 1. Pause settlement: callback fencing alone cannot publish PAUSED while the
---    native probe remains live, pinned, or ambiguously cancelled.
--- 2. Exact retry: false, nil, and throwing termination retry the same handle;
---    a late terminal settles it without entering start_server.
--- 3. Start refusal: mutate-then-false/nil/throw retains cleanup ownership and
---    refuses a successor until the original native callback proves exit.
--- 4. Port replay: the real menu caller routes through the model capability;
---    rollback stays fenced and only the matching post-RESUME epoch can replay.
--- 5. Provenance: activation, model switch, and startup each join only their own
---    opaque capability even when all three real ScriptControl owners coexist.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"hs",
	"tests.stubs.hs",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.fs_dir",
	"infra.dialog_util",
	"infra.keycodes",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"adapters.key_state",
	"adapters.task_lifecycle",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"modules.keylogger",
	"modules.llm",
	"modules.llm.api_common",
	"modules.llm.api_mlx",
	"modules.llm.mlx_deps_checker",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"modules.llm.warmup_controller",
	"modules.shortcuts.script_control",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"ui.menu.menu_llm.profile_label",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_mlx_hf",
	"ui.menu.menu_llm.models_manager_mlx_server",
	"ui.menu.menu_llm.models_manager_mlx_download",
	"ui.menu.menu_llm.models_manager_mlx",
	"ui.menu.menu_llm.activation_pause_owner",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.startup_controller",
}





-- ====================================
-- ====================================
-- ======= 1/ Fixture Utilities =======
-- ====================================
-- ====================================

--- Runs one isolated fixture and restores the exact global Hammerspoon table.
--- @param callback function Fixture body receiving the native-state record.
local function with_fixture(callback)
	local saved_hs = _G.hs
	local saved_getenv = os.getenv
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			-- The production driver always runs in a macOS login environment. Keep
			-- that contract explicit when this fixture executes under Windows Lua.
			os.getenv = function(name)
				if name == "HOME" then return "/Users/fixture" end
				return saved_getenv(name)
			end
			package.loaded["tests.stubs.hs"] = nil
			local hs_fixture = require("tests.stubs.hs")
			hs_fixture.__reset()
			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture

			local native = {
				tasks = {},
				cancel_handles = {},
				server_starts = {},
				server_ports = {},
				replay_timers = {},
				start_mode = "true",
				cancel_mode = "true",
			}

			hs_fixture.task.new = function(executable, on_done, third_or_args, fourth)
				local args = type(third_or_args) == "table" and third_or_args
					or fourth
				local on_stream = type(third_or_args) == "function"
					and third_or_args or nil
				local task = {
					executable = executable,
					args = args,
					on_done = on_done,
					on_stream = on_stream,
					started = false,
					running_state = false,
					start_calls = 0,
					terminate_calls = 0,
				}
				function task:start()
					self.start_calls = self.start_calls + 1
					self.started = true
					self.running_state = true
					if native.start_mode == "throw" then
						error("synthetic requirement start failure")
					end
					if native.start_mode == "false" then return false end
					if native.start_mode == "nil" then return nil end
					return true
				end
				function task:terminate()
					self.terminate_calls = self.terminate_calls + 1
					native.cancel_handles[#native.cancel_handles + 1] = self
					if native.cancel_mode == "throw" then
						error("synthetic requirement termination failure")
					end
					if native.cancel_mode == "false" then return false end
					if native.cancel_mode == "nil" then return nil end
					return true
				end
				function task:isRunning() return self.running_state end
				native.tasks[#native.tasks + 1] = task
				return task
			end

			callback(native, hs_fixture)
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	os.getenv = saved_getenv
	if not outcome[1] then error(outcome[2], 0) end
end

--- Installs strict shared dependencies for ScriptControl and the real manager.
--- @param native table Native-state record receiving server starts.
local function install_subject_stubs(native)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = { notify = function() return true end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.fs_dir"] = { entries = function() return {} end }
	package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 106,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE = 108,
		BACKSPACE = 51,
		RETURN = 36,
		ESCAPE = 53,
	}
	package.loaded["modules.llm.api_common"] = {
		protected_call = function(callback, _, ...)
			if type(callback) ~= "function" then return false end
			return xpcall(callback, debug.traceback, ...)
		end,
	}
	package.loaded["modules.llm.api_mlx"] = {
		get_port = function() return 8080 end,
		pause_warmup = function() return true end,
		resume_warmup = function() return true end,
	}
	package.loaded["modules.llm.mlx_deps_checker"] = {}
	package.loaded["modules.llm"] = {
		BUILTIN_PROFILES = {},
		DEFAULT_STATE = { llm_num_predictions = 1 },
		set_active_profile = function() return true end,
		set_llm_model_mlx = function() return true end,
		set_llm_model_ollama = function() return true end,
	}
	package.loaded["ui.menu.menu_llm.profile_label"] = {
		format = function(label) return label end,
	}
	package.loaded["ui.menu.menu_llm.prediction_lock_registry"] = {
		new = function() error("fixture injects an exact prediction-lock registry") end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_hf"] = {
		install = function(ctx)
			ctx.obj.get_mlx_repo = function(name)
				return "fixture/" .. tostring(name)
			end
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_server"] = {
		install = function(ctx)
			ctx.obj.start_server = function(target, on_success, _, opts)
				native.server_starts[#native.server_starts + 1] = target
				native.server_ports[#native.server_ports + 1] =
					type(opts) == "table" and opts._mlx_port or nil
				if type(on_success) ~= "function" then return true end
				local ok, result = xpcall(on_success, debug.traceback)
				return ok == true and result ~= false
			end
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_download"] = {
		install = function(ctx)
			ctx.obj.pull_model = function() return true end
		end,
	}

	local admission_fence = nil
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "physical", nil end,
	}
	package.loaded["adapters.synthetic_input"] = {
		when_idle = function(callback)
			callback()
			return true
		end,
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
	local function notify_timer_settlement(handle)
		local observers = handle.settlement_observers or {}
		handle.settlement_observers = {}
		for _, observer in ipairs(observers) do observer() end
	end
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			local handle = {
				timer = {},
				committed = true,
				settlement_observers = {},
				callback = callback,
				delay = delay,
			}
			function handle:fire()
				if self.timer == nil or self.committed ~= true then return false end
				self.committed = false
				self.timer = nil
				notify_timer_settlement(self)
				callback()
				return true
			end
			native.replay_timers[#native.replay_timers + 1] = handle
			return handle, true
		end,
		every = function()
			return { timer = {}, committed = true, settlement_observers = {} }, true
		end,
		cancel = function(handle)
			if type(handle) ~= "table" or handle.timer == nil then return true end
			handle.committed = false
			handle.timer = nil
			notify_timer_settlement(handle)
			return true
		end,
		onSettled = function(handle, observer)
			if type(handle) ~= "table" or type(observer) ~= "function" then
				return false
			end
			if handle.timer == nil then observer() return true end
			handle.settlement_observers[#handle.settlement_observers + 1] = observer
			return true
		end,
	}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.gestures.actions"] = {
		get_label = function(name) return name end,
		execute_single = function() return true end,
		SG_NAMES = { "none", "script_pause_toggle" },
		AX_NAMES = {},
	}
	for _, module_name in ipairs({
		"modules.llm.warmup_controller",
		"modules.llm.api_ollama",
		"modules.llm.api_remote",
	}) do
		package.loaded[module_name] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
	end
	for _, module_name in ipairs({ "ui.wpm.wpm_menubar", "ui.wpm.wpm_widget" }) do
		package.loaded[module_name] = {
			is_running = function() return false end,
			stop = function() return true end,
			resume_after_pause = function() return true end,
		}
	end
	package.loaded["platform.remap.onboarding"] = {
		stop = function() return true end,
	}
	package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
	package.loaded["modules.keylogger"] = {
		resync_context = function() return true end,
		log_shortcut = function() return true end,
	}
end

--- Builds the real MLX manager over the real TaskLifecycle adapter.
--- @param script_control table|nil Real controller proving owned app dispatches.
--- @param shared_system_check function|nil Shared preflight boundary override.
--- @return table manager Exact requirements manager.
--- @return table module Manager module exposing the canonical GC root.
local function build_manager(script_control, shared_system_check)
	package.loaded["adapters.task_lifecycle"] = nil
	local manager_module = require("ui.menu.menu_llm.models_manager_mlx")
	local presets = {
		{
			families = {
				{
					models = {
						{
							name = "fixture-model",
							urls = {
								mlx = "https://huggingface.co/fixture/fixture-model",
							},
						},
					},
				},
			},
		},
	}
	local manager = manager_module.new({
		active_tasks = {},
		state = { llm_backend = "mlx" },
		script_control = script_control,
		update_icon = function() return true end,
		reset_menubar = function() return true end,
		save_prefs = function() return true end,
		update_menu = function() return true end,
		shared_system_check = shared_system_check,
	}, presets)
	manager.get_installed_models = function()
		return { ["fixture-model"] = true }
	end
	return manager, manager_module
end

--- Starts the real ScriptControl module with literal lifecycle contracts.
--- @return table script_control Running ScriptControl module.
local function start_script_control()
	local script_control = require("modules.shortcuts.script_control")
	local keymap = {
		pause_processing = function() return true end,
		resume_processing = function() return true end,
		reset_predictions = function() return true end,
		reset_predictions_for_pause = function() return true end,
	}
	local shortcuts = {
		is_bindings_started = function() return false end,
		pause_bindings = function() return true end,
		resume_bindings = function() return true end,
		release_bindings_pause_claim = function() return true end,
	}
	local gestures = {
		is_enabled = function() return false end,
		suspend = function() return true end,
		resume = function() return true end,
	}
	helpers.assert_true(script_control.start(keymap, shortcuts, gestures))
	return script_control
end

--- Wraps ScriptControl while exposing the exact dynamic owner registered by the
--- model manager. Calls still reach the real coordinator; the record only makes
--- the production maintenance-capability wiring observable to this regression.
--- @param script_control table Running real ScriptControl module.
--- @return table facade Delegating ScriptControl facade.
--- @return table registration Observed owner identity and implementation.
local function observe_maintenance_registration(script_control)
	local registration = {}
	local facade = {
		is_paused = function() return script_control.is_paused() end,
		is_pause_transition_pending = function()
			return script_control.is_pause_transition_pending()
		end,
		register_pause_owner = function(owner_id, owner)
			registration.owner_id = owner_id
			registration.owner = owner
			registration.accepted =
				script_control.register_pause_owner(owner_id, owner)
			return registration.accepted
		end,
	}
	return facade, registration
end

--- Creates a strict shared prediction-lock ledger for the two subjects.
--- @return table registry Observable literal-boolean registry.
local function build_prediction_locks()
	local owners = {}
	local registry
	registry = {
		acquire_calls = 0,
		release_calls = 0,
		ensure_calls = 0,
		acquire = function(owner)
			registry.acquire_calls = registry.acquire_calls + 1
			if owners[owner] == true then return false end
			owners[owner] = true
			return true
		end,
		ensure_locked = function(owner)
			registry.ensure_calls = registry.ensure_calls + 1
			owners[owner] = true
			return true
		end,
		release = function(owner)
			registry.release_calls = registry.release_calls + 1
			if owners[owner] ~= true then return false end
			owners[owner] = nil
			return true
		end,
		apply_preference = function() return true end,
	}
	return registry
end

--- Returns the newest live owned one-shot timer with the requested delay.
--- @param native table Native-state record holding scheduler capabilities.
--- @param delay number Requested delay.
--- @return table|nil timer Matching timer handle.
local function newest_live_timer(native, delay)
	for index = #native.replay_timers, 1, -1 do
		local timer = native.replay_timers[index]
		if timer.delay == delay and timer.timer ~= nil
			and timer.committed == true then
			return timer
		end
	end
	return nil
end





-- ==========================================
-- ==========================================
-- ======= 2/ Pause Join Compositions =======
-- ==========================================
-- ==========================================

helpers.describe("HS-012 MLX requirement-task pause joins", function()
	helpers.it("refuses an anonymous probe when ScriptControl can pause", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local manager = build_manager(script_control)
			local reason = nil
			helpers.assert_eq(manager.check_requirements("fixture-model",
				function() return true end,
				function(value) reason = value return true end), false)
			helpers.assert_eq(reason, "missing_requirement_owner")
			helpers.assert_eq(native.tasks, {},
				"an app-owned manager must not construct an unpausable native probe")
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("rejects a nil shared system-check admission", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local shared_calls = 0
			local manager = build_manager(script_control, function()
				shared_calls = shared_calls + 1
				return nil
			end)
			manager.get_installed_models = function() return {} end
			local capability = manager.create_requirement_owner("activation")
			local terminal = { success = 0, cancel = 0 }
			helpers.assert_true(manager.check_requirements("fixture-model", function()
				terminal.success = terminal.success + 1
				return true
			end, function()
				terminal.cancel = terminal.cancel + 1
				return true
			end, {
				requirement_owner = capability,
				is_current = function() return true end,
			}))
			helpers.assert_eq(#native.tasks, 1)
			native.tasks[1].on_done(0, "", "")
			helpers.assert_eq(shared_calls, 1)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(native.server_starts, {})
			helpers.assert_eq(#native.tasks, 1,
				"nil must not be normalized into a committed download successor")
			helpers.assert_true(script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins model-switch requirement cancellation after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "old-model",
						llm_model_mlx = "old-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					local switcher = require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = {},
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_shortcut = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						deps = { script_control = script_control },
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_trigger_hk = function() return nil end,
						get_profile_hks = function() return {} end,
						prediction_locks = build_prediction_locks(),
					})

					helpers.assert_true(switcher.switch_model("fixture-model"))
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false,
						"an unsettled exact task must prevent PAUSED publication")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(manager_module._active_tasks[task], true)
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"pause retry must target the same native handle")
					helpers.assert_eq(#native.tasks, 1,
						"cleanup debt must refuse a successor requirement task")

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"late and duplicate revoked terminals must stay inert")
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)

					native.cancel_mode = "true"
					helpers.assert_true(switcher.switch_model("fixture-model"))
					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {})
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"only a fresh post-RESUME authorization may start the server")
					helpers.assert_true(script_control.stop())
				end)
			end)

		helpers.it("joins startup requirement cancellation after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "fixture-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					local startup_locks = build_prediction_locks()
					local check_startup = require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = { set_llm_backend_name = function() return true end },
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_shortcut = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						deps = {
							script_control = script_control,
							update_menu = function() return true end,
						},
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_trigger_hk = function() return nil end,
						get_profile_hks = function() return {} end,
						prediction_locks = startup_locks,
					})

					helpers.assert_true(check_startup())
					local primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(primary)
					primary:fire()
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_true(startup_locks.ensure_calls > 0,
						"the fixed owner order must reach the true startup owner")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task)
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {})
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)

					native.cancel_mode = "true"
					local resumed_primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(resumed_primary)
					resumed_primary:fire()
					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {})
					local resumed_backup = newest_live_timer(native, 3)
					helpers.assert_not_nil(resumed_backup)
					resumed_backup:fire()
					helpers.assert_eq(#native.tasks, 3,
						"primary and backup may overlap below one startup capability")
					native.cancel_mode = mode
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"startup may dispatch the server only after committed RESUME")
					local losing_task = native.tasks[3]
					helpers.assert_eq(losing_task.terminate_calls, 1,
						"the winning terminal must join its losing requirement sibling")
					helpers.assert_eq(startup_locks.release_calls, 0,
						"predictions stay locked until the losing task physically settles")
					losing_task.on_done(0, "", "")
					losing_task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" },
						"the revoked loser cannot publish a second server start")
					native.cancel_mode = "true"
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(startup_locks.release_calls, 1,
						"the winning cycle releases its lock once after sibling settlement")

					-- A requirement task whose start mutates then refuses is born below
					-- the startup timer. Aborting that cycle must join the same task and
					-- retain the prediction lock until exact physical settlement.
					native.start_mode = mode
					native.cancel_mode = mode
					helpers.assert_true(check_startup())
					local refused_primary = newest_live_timer(native, 1)
					helpers.assert_not_nil(refused_primary)
					refused_primary:fire()
					helpers.assert_eq(#native.tasks, 4)
					local refused_task = native.tasks[4]
					helpers.assert_eq(refused_task.terminate_calls, 2,
						"manager rollback and startup abort must join one exact task")
					helpers.assert_eq(startup_locks.release_calls, 1,
						"an unsettled requirement task must keep predictions locked")
					helpers.assert_eq(check_startup(), false,
						"abort cleanup debt must refuse a successor startup cycle")
					helpers.assert_eq(#native.tasks, 4)
					helpers.assert_eq(refused_task.terminate_calls, 3)

					refused_task.on_done(0, "", "")
					refused_task.on_done(0, "", "")
					native.start_mode = "true"
					native.cancel_mode = "true"
					helpers.assert_true(check_startup())
					helpers.assert_eq(startup_locks.release_calls, 2,
						"the old prediction lock releases once after exact task settlement")
					helpers.assert_eq(startup_locks.acquire_calls, 3,
						"the fresh startup cycle acquires its own lock only after cleanup")
					helpers.assert_eq(#native.tasks, 4,
						"preflight and rearm must not create a native task synchronously")
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 3/ Activation Provenance =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX activation requirement ownership", function()
	helpers.it("wires a dedicated capability into the real activation caller", function()
		local source = helpers.read_driver_source("local activation_generation = 0")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"the uniquely anchored LLM activation source must be readable")
		local setup_begin = source:find("local activation_generation = 0", 1, true)
		local setup_end = setup_begin and source:find(
			"local function build_item", setup_begin, true) or nil
		helpers.assert_not_nil(setup_begin)
		helpers.assert_not_nil(setup_end)
		local setup = source:sub(setup_begin, setup_end - 1)
		helpers.assert_true(setup:find(
			"models_mgr.create_requirement_owner", 1, true) ~= nil
			and setup:find("\"llm_activation\"", 1, true) ~= nil,
			"activation must create its own opaque manager capability")
		helpers.assert_true(source:find(
			"requirement_owner = activation_requirement_owner", 1, true) ~= nil,
			"activation requirements must carry the activation capability")
		helpers.assert_true(setup:find(
			"models_mgr.pause_requirements", 1, true) ~= nil
			and setup:find("activation_requirement_owner", 1, true) ~= nil,
			"the llm_activation pause owner must join that same capability")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps activation in its own owner after " .. mode,
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "fixture-model",
						llm_model_mlx = "fixture-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					local activation_capability = manager.create_requirement_owner(
						"llm_activation")
					helpers.assert_not_nil(activation_capability)
					local activation = require(
						"ui.menu.menu_llm.activation_pause_owner").new({
						script_control = script_control,
						pause_join = function()
							return manager.pause_requirements(activation_capability)
						end,
					})
					require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = {},
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_shortcut = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						deps = { script_control = script_control },
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_trigger_hk = function() return nil end,
						get_profile_hks = function() return {} end,
						prediction_locks = build_prediction_locks(),
					})

					local token
					local function dispatch_activation()
						local authorization = activation.capture(token)
						if authorization == nil then return false end
						return manager.check_requirements("fixture-model", function()
							return activation.complete(token)
						end, function()
							return activation.complete(token)
						end, {
							requirement_owner = activation_capability,
							is_current = function()
								return activation.is_current(token, authorization)
							end,
						})
					end
					token = activation.begin(function(_, replay_revoked_requirements)
						if replay_revoked_requirements ~= true then return true end
						return dispatch_activation()
					end)
					helpers.assert_not_nil(token)
					helpers.assert_true(dispatch_activation())
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[1], task,
						"llm_activation must cancel its own exact native handle")
					helpers.assert_eq(#native.replay_timers, 0,
						"failed-PAUSE rollback must not dispatch a sibling probe")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"activation retry must retain the same requirement handle")
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {})
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 1)
					helpers.assert_true(native.replay_timers[1]:fire())
					helpers.assert_eq(#native.tasks, 2,
						"only the dedicated activation intent may replay after RESUME")
					helpers.assert_eq(native.server_starts, {})
					native.tasks[2].on_done(0, "", "")
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)




-- =========================================
-- =========================================
-- ======= 4/ Port-Restart Replay =========
-- =========================================
-- =========================================

helpers.describe("HS-012 MLX port requirement replay ownership", function()
	helpers.it("routes the real port caller through the ModelSwitcher owner", function()
		-- A unique declaration locates menu_llm/init.lua without pinning its path.
		-- The bounded function body prevents another manager call elsewhere in that
		-- file from making this wiring assertion ambiguous.
		local source = helpers.read_driver_source(
			"local mlx_port_transition_generation = 0")
		helpers.assert_true(type(source) == "string" and source ~= "",
			"the uniquely anchored LLM menu source must be readable")
		local begin_at = source:find(
			"local function restart_mlx_for_current_port", 1, true)
		local end_at = begin_at and source:find(
			"switcher = ModelSwitcher.new", begin_at, true) or nil
		helpers.assert_not_nil(begin_at)
		helpers.assert_not_nil(end_at)
		local restart_body = source:sub(begin_at, end_at - 1)
		helpers.assert_true(restart_body:find(
			"switcher.dispatch_resumable_requirements", 1, true) ~= nil,
			"the committed port restart must enter the replayable model capability")
		helpers.assert_true(restart_body:find(
			"models_mgr.check_requirements(", 1, true) == nil,
			"the port restart must not dispatch an anonymous native probe")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("replays the exact port intent after " .. mode .. " rollback",
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local manager, manager_module = build_manager(script_control)
					local state = {
						llm_backend = "mlx",
						llm_enabled = true,
						llm_model = "fixture-model",
						llm_model_mlx = "fixture-model",
						llm_active_profile = "basic",
					}
					local manager_path = {
						create_requirement_owner = manager.create_requirement_owner,
						check_requirements = manager.check_requirements,
						force_mlx_check = manager.check_requirements,
						pause_requirements = manager.pause_requirements,
						get_installed_models = manager.get_installed_models,
						get_presets = function() return {} end,
						get_model_info = function() return { params = 1 } end,
						get_actual_model_name = function(name) return name end,
					}
					local switcher = require("ui.menu.menu_llm.model_switcher").new({
						state = state,
						models_mgr = manager_path,
						keymap = {
							set_llm_model = function() return true end,
							set_llm_display_model_name = function() return true end,
						},
						save_prefs = function() return true end,
						update_menu = function() return true end,
						runtime_gate = function() return not script_control.is_paused() end,
						pause_epoch = script_control.get_pause_epoch,
						script_control = script_control,
						prediction_locks = build_prediction_locks(),
					})
					require("ui.menu.menu_llm.startup_controller").new({
						state = state,
						keymap = {},
						models_mgr = manager_path,
						guarded_check_requirements = manager.check_requirements,
						save_prefs = function() return true end,
						update_menu = function() return true end,
						apply_llm_shortcut = function() return true end,
						apply_llm_profile_shortcut = function() return true end,
						activate_hotkey = function() return true end,
						mlx_deps_checker = {},
						deps = { script_control = script_control },
						get_startup_silence = function() return false end,
						set_startup_silence = function() return true end,
						get_trigger_hk = function() return nil end,
						get_profile_hks = function() return {} end,
						prediction_locks = build_prediction_locks(),
					})

					helpers.assert_true(switcher.dispatch_resumable_requirements(
						"fixture-model", nil, nil, {
							silent_notifications = true,
							_mlx_port = 9090,
						}))
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_eq(manager_module._active_tasks[task], true)
					native.cancel_mode = mode

					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false,
						"failed PAUSE rollback must not publish or replay the port intent")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(#native.tasks, 1)
					helpers.assert_eq(#native.replay_timers, 0,
						"ACTIVE rollback is not authority for a deferred restart")
					script_control.pause_all()
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"port rollback retry must target the same native handle")
					helpers.assert_eq(#native.tasks, 1)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"late and duplicate revoked port terminals must stay inert")
					helpers.assert_eq(manager_module._active_tasks[task], nil)

					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 1)
					local stale_stage = native.replay_timers[1]

					-- A newer PAUSE cancels the exact staged callback. Delivering its raw
					-- closure afterward proves identity/epoch fencing, then the matching
					-- RESUME obtains a distinct replay authorization.
					helpers.assert_true(script_control.pause_all())
					helpers.assert_true(script_control.is_paused())
					helpers.assert_eq(stale_stage.timer, nil)
					stale_stage.callback()
					helpers.assert_eq(#native.tasks, 1)
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#native.replay_timers, 2)
					helpers.assert_true(native.replay_timers[2]:fire())

					helpers.assert_eq(#native.tasks, 2)
					helpers.assert_eq(native.server_starts, {},
						"replay authorizes only a fresh probe, never an early server")
					native.tasks[2].on_done(0, "", "")
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
					helpers.assert_eq(native.server_ports, { 9090 },
						"the replay must retain the originally committed port identity")
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 5/ Start-Refusal Cleanup =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX requirement start-refusal ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a mutate-then-" .. mode .. " start until exact terminal",
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local manager, manager_module = build_manager()
					local requirement_owner = manager.create_requirement_owner(
						"start_refusal")
					helpers.assert_not_nil(requirement_owner)
					native.start_mode = mode
					native.cancel_mode = mode
					local cancellations = 0

					helpers.assert_eq(manager.check_requirements("fixture-model",
						function() return true end,
						function()
							cancellations = cancellations + 1
							return true
						end, { requirement_owner = requirement_owner }), false)
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_true(task.started,
						"the faithful start double must mutate before refusing")
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(manager_module._active_tasks[task], true,
						"ambiguous start refusal must keep the exact GC pin")
					helpers.assert_eq(cancellations, 1)

					helpers.assert_eq(manager.check_requirements("fixture-model",
						function() return true end,
						function() return true end,
						{ requirement_owner = requirement_owner }), false)
					helpers.assert_eq(native.cancel_handles[2], task,
						"successor preflight must retry cleanup on the same handle")
					helpers.assert_eq(#native.tasks, 1,
						"no successor may launch before native settlement")

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(native.server_starts, {},
						"a refused start's late terminal is permanently unauthorized")
					helpers.assert_eq(manager_module._active_tasks[task], nil)

					native.start_mode = "true"
					native.cancel_mode = "true"
					helpers.assert_true(manager.check_requirements("fixture-model",
						function() return true end,
						function() return true end,
						{ requirement_owner = requirement_owner }))
					helpers.assert_eq(#native.tasks, 2)
					native.tasks[2].on_done(0, "", "")
					helpers.assert_eq(native.server_starts, { "fixture-model" })
				end)
			end)
	end
end)





-- ========================================
-- ========================================
-- ======= 6/ Maintenance Ownership =======
-- ========================================
-- ========================================

helpers.describe("HS-012 MLX deletion pause ownership", function()
	helpers.it("blocks PAUSED until the exact deletion task reports terminal", function()
		with_fixture(function(native)
			install_subject_stubs(native)
			local script_control = start_script_control()
			local manager, manager_module = build_manager(script_control)
			manager._installed_cache_ts = 99
			native.cancel_mode = "false"

			helpers.assert_true(manager.delete_model("fixture-model"))
			helpers.assert_eq(#native.tasks, 1)
			local task = native.tasks[1]
			helpers.assert_eq(task.executable, "/bin/rm")
			helpers.assert_eq(task.args, { "-rf",
				(os.getenv("HOME") or "")
					.. "/.cache/huggingface/hub/models--fixture--fixture-model" })
			helpers.assert_eq(manager_module._active_tasks[task], true)

			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"PAUSED cannot publish while deletion termination is ambiguous")
			helpers.assert_eq(native.cancel_handles[1], task)
			helpers.assert_eq(manager._installed_cache_ts, 99)

			task.on_done(0, "", "")
			task.on_done(0, "", "")
			helpers.assert_eq(manager_module._active_tasks[task], nil)
			helpers.assert_eq(manager._installed_cache_ts, 99,
				"a pause-revoked deletion terminal cannot publish cache mutation")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains a mutate-then-" .. mode .. " deletion start refusal",
			function()
				with_fixture(function(native)
					install_subject_stubs(native)
					local script_control = start_script_control()
					local control, registration =
						observe_maintenance_registration(script_control)
					local manager, manager_module = build_manager(control)
					helpers.assert_eq(registration.owner_id,
						"mlx_model_maintenance")
					helpers.assert_true(registration.accepted)
					helpers.assert_type(registration.owner, "table")
					helpers.assert_type(registration.owner.pause, "function")
					helpers.assert_type(registration.owner.resume, "function")
					helpers.assert_eq(control.is_paused(), false)
					helpers.assert_eq(control.is_pause_transition_pending(), false)
					helpers.assert_eq(manager.get_mlx_repo("fixture-model"),
						"fixture/fixture-model")
					helpers.assert_eq(os.getenv("HOME"), "/Users/fixture")
					manager._installed_cache_ts = 99
					native.start_mode = mode
					native.cancel_mode = mode

					helpers.assert_eq(manager.delete_model("fixture-model"), false)
					helpers.assert_eq(#native.tasks, 1)
					local task = native.tasks[1]
					helpers.assert_true(task.started)
					helpers.assert_eq(native.cancel_handles[1], task)
					helpers.assert_eq(task.terminate_calls, 1)
					helpers.assert_eq(manager_module._active_tasks[task], true)
					helpers.assert_eq(manager._installed_cache_ts, 99)

					helpers.assert_eq(manager.delete_model("fixture-model"), false)
					helpers.assert_eq(#native.tasks, 1,
						"cleanup debt must not construct a sibling deletion task")
					helpers.assert_eq(native.cancel_handles[2], task,
						"successor preflight must retry the identical retained task")
					helpers.assert_eq(task.terminate_calls, 2)

					task.on_done(0, "", "")
					task.on_done(0, "", "")
					helpers.assert_eq(manager_module._active_tasks[task], nil)
					helpers.assert_eq(manager._installed_cache_ts, 99)
					helpers.assert_true(script_control.stop())
				end)
			end)
	end
end)
