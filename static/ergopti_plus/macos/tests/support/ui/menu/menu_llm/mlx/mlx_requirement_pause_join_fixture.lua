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
	"core.logger.engine.logger",
	"core.ui.engine.notifications",
	"core.i18n.engine.i18n",
	"core.fs.engine.dir",
	"core.ui.engine.dialog_util",
	"platform.input.keycodes",
	"adapters.event_provenance",
	"platform.input.synthetic_input",
	"core.events.timer_scheduler",
	"platform.input.key_state",
	"core.process.adapters.task_lifecycle",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"modules.keystats",
	"ai.engine",
	"ai.engine.api.common",
	"ai.engine.api.mlx",
	"ai.engine.local_servers.mlx_deps_checker",
	"ai.engine.local_servers.mlx_bootstrap_diagnosis",
	"ai.engine.api.ollama",
	"ai.engine.api.remote",
	"ai.engine.local_servers.warmup_controller",
	"modules.shortcuts.script_control",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"core.ui.ui.tooltip",
	"ai.ui.menu.profile_label",
	"ai.ui.menu.prediction_lock_registry",
	"ai.ui.menu.requirement_operation_registry",
	"ai.ui.menu.models.manager_mlx_hf",
	"ai.ui.menu.models.manager_mlx_server",
	"ai.ui.menu.models.manager_mlx_download",
	"ai.ui.menu.models.manager_mlx",
	"ai.ui.menu.models.mlx_repair_offer",
	"ai.ui.menu.activation_pause_owner",
	"ai.ui.menu.models.switcher",
	"ai.ui.menu.startup_controller",
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
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["core.ui.engine.notifications"] = { notify = function() return true end }
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
	package.loaded["core.fs.engine.dir"] = { entries = function() return {} end }
	package.loaded["core.ui.engine.dialog_util"] = { block_alert = function() return false end }
	package.loaded["platform.input.keycodes"] = {
		F13_KARABINER_RETURN = 106,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE = 108,
		BACKSPACE = 51,
		RETURN = 36,
		ESCAPE = 53,
	}
	package.loaded["ai.engine.api.common"] = {
		protected_call = function(callback, _, ...)
			if type(callback) ~= "function" then return false end
			return xpcall(callback, debug.traceback, ...)
		end,
	}
	package.loaded["ai.engine.api.mlx"] = {
		get_port = function() return 8080 end,
		pause_warmup = function() return true end,
		resume_warmup = function() return true end,
	}
	package.loaded["ai.engine.local_servers.mlx_deps_checker"] = { import_probe = require("tests.support.modules.llm.mlx_import_probe").read }
	package.loaded["ai.engine"] = {
		BUILTIN_PROFILES = {},
		DEFAULT_STATE = { llm_num_predictions = 1 },
		set_active_profile = function() return true end,
		set_llm_model_mlx = function() return true end,
		set_llm_model_ollama = function() return true end,
	}
	package.loaded["ai.ui.menu.profile_label"] = {
		format = function(label) return label end,
	}
	package.loaded["ai.ui.menu.prediction_lock_registry"] = {
		new = function() error("fixture injects an exact prediction-lock registry") end,
	}
	package.loaded["ai.ui.menu.models.manager_mlx_hf"] = {
		install = function(ctx)
			ctx.obj.get_mlx_repo = function(name)
				return "fixture/" .. tostring(name)
			end
		end,
	}
	package.loaded["ai.ui.menu.models.manager_mlx_server"] = {
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
	package.loaded["ai.ui.menu.models.manager_mlx_download"] = {
		install = function(ctx)
			ctx.obj.pull_model = function() return true end
		end,
	}

	local admission_fence = nil
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "physical", nil end,
	}
	package.loaded["platform.input.synthetic_input"] = {
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
	package.loaded["core.events.timer_scheduler"] = {
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
	package.loaded["platform.input.key_state"] = {
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
		"ai.engine.local_servers.warmup_controller",
		"ai.engine.api.ollama",
		"ai.engine.api.remote",
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
	package.loaded["core.ui.ui.tooltip"] = { hide_forced = function() return true end }
	package.loaded["modules.keystats"] = {
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
	package.loaded["core.process.adapters.task_lifecycle"] = nil
	local manager_module = require("ai.ui.menu.models.manager_mlx")
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
