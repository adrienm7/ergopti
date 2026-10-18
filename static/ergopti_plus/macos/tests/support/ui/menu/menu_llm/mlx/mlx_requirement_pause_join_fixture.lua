--- tests/support/ui/menu/menu_llm/mlx/mlx_requirement_pause_join_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_mlx_requirement_pause_join
--- DESCRIPTION:
--- Prelude shared by the test_mlx_requirement_pause_join_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
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
	"modules.llm.mlx_bootstrap_diagnosis",
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
	"ui.menu.menu_llm.mlx_repair_offer",
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
				return helpers.attach_native_task_environment(task)
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

return {
	OWNED_MODULES = OWNED_MODULES,
	build_manager = build_manager,
	build_prediction_locks = build_prediction_locks,
	install_subject_stubs = install_subject_stubs,
	newest_live_timer = newest_live_timer,
	observe_maintenance_registration = observe_maintenance_registration,
	start_script_control = start_script_control,
	with_fixture = with_fixture,
}
