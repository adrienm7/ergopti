--- tests/unit/modules/shortcuts/pause_owners/startup_fixture.lua

--- ==============================================================================
--- MODULE: Pause Startup Owner Fixture
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module

local function load_real_startup_owner(initial_stop_mode, options)
	options = options or {}
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	local timers = {}
	local stop_mode = initial_stop_mode or "true"
	local arm_mode = options.arm_mode or "true"
	local arm_fail_delay = options.arm_fail_delay
	local arm_failures_left = options.arm_failures or 0
	hs_stub.timer.new = function(delay, callback)
		local timer = {
			delay = delay,
			fn = callback,
			running_state = false,
		}
		function timer:start()
			self.running_state = true
			if arm_failures_left > 0
				and (arm_fail_delay == nil or arm_fail_delay == delay) then
				arm_failures_left = arm_failures_left - 1
				if arm_mode == "false" then return false end
				if arm_mode == "nil" then return nil end
				if arm_mode == "throw" then error("startup timer acquisition exploded") end
				if arm_mode == "sync" then callback() end
			end
			return self
		end
		function timer:stop()
			if self.delay == 1 or self.delay == 3 then
				if stop_mode == "false" then return false end
				if stop_mode == "nil" then return nil end
				if stop_mode == "throw" then error("startup timer stop exploded") end
			end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		timers[#timers + 1] = timer
		return timer
	end

	local epoch = 0
	local paused = options.initial_paused == true
	local registered_owner = nil
	local control
	if options.script_control then
		local supplied_control = options.script_control
		control = {
			get_pause_epoch = function() return supplied_control.get_pause_epoch() end,
			is_paused = function() return supplied_control.is_paused() end,
			register_pause_owner = function(name, owner)
				helpers.assert_eq(name, "llm_startup")
				registered_owner = owner
				return supplied_control.register_pause_owner(name, owner)
			end,
		}
	else
		control = {
			get_pause_epoch = function() return epoch end,
			is_paused = function() return paused end,
			register_pause_owner = function(name, owner)
				helpers.assert_eq(name, "llm_startup")
				registered_owner = owner
				if paused then return owner.pause() == true end
				return true
			end,
		}
	end
	local prediction_box = options.prediction_box or { value = true }
	local prediction_calls = options.prediction_calls or {}
	local prediction_mode = options.prediction_mode or "true"
	local keymap = options.keymap or {
		get_llm_enabled = function() return prediction_box.value end,
		set_llm_enabled = function(enabled)
			prediction_box.value = enabled == true
			prediction_calls[#prediction_calls + 1] = enabled
			if prediction_mode == "false" then return false end
			if prediction_mode == "nil" then return nil end
			if prediction_mode == "throw" then error("startup prediction setter exploded") end
			return true
		end,
		set_llm_backend_name = function() end,
	}
	local probes = {}
	local dispatch_mode = options.dispatch_mode or "true"
	local saves = 0
	local menu_updates = 0
	local requirement_owner = {}
	local models_mgr = {
		create_requirement_owner = function(label)
			helpers.assert_eq(label, "startup")
			return requirement_owner
		end,
		pause_requirements = function(owner)
			helpers.assert_true(owner == requirement_owner,
				"startup must join only its exact requirement capability")
			return true
		end,
		get_installed_models = function() return { model = true } end,
		force_mlx_check = function(model, on_ok, on_fail, opts)
			helpers.assert_true(opts.requirement_owner == requirement_owner,
				"startup probes must carry their opaque requirement capability")
			probes[#probes + 1] = {
				model = model,
				on_ok = on_ok,
				on_fail = on_fail,
				opts = opts,
			}
			if options.sync_terminal == "ok" then on_ok() end
			if options.sync_terminal == "fail" then on_fail("sync") end
			if dispatch_mode == "false" then return false end
			if dispatch_mode == "nil" then return nil end
			if dispatch_mode == "throw" then error("startup probe dispatch exploded") end
			return true
		end,
		reattach_download = options.reattach_download,
		has_reattached_download = options.has_reattached_download,
		pause_reattached_download = options.pause_reattached_download,
		resume_reattached_download = options.resume_reattached_download,
	}
	local state = options.state or {
		llm_enabled = true,
		llm_backend = "mlx",
		llm_model = "startup-model",
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.llm"] = {
		BUILTIN_PROFILES = {},
		get_current_model = function() return state.llm_model end,
	}
	reset_module("adapters.timer_scheduler")
	reset_module("ui.menu.menu_llm.startup_controller")
	local StartupController = require("ui.menu.menu_llm.startup_controller")
	local check_startup = StartupController.new({
		state = state,
		keymap = keymap,
		models_mgr = models_mgr,
		guarded_check_requirements = function(_, on_ok) on_ok(); return true end,
		save_prefs = function() saves = saves + 1; return true end,
		update_menu = function() menu_updates = menu_updates + 1; return true end,
		apply_llm_shortcut = function() return true end,
		apply_llm_profile_shortcut = function() return true end,
		activate_hotkey = function() return true end,
		mlx_deps_checker = {},
		deps = {
			script_control = control,
			update_menu = function() menu_updates = menu_updates + 1; return true end,
		},
		prediction_locks = options.prediction_locks,
		get_startup_silence = function() return false end,
		set_startup_silence = function() return true end,
		get_trigger_hk = function() return nil end,
		get_profile_hks = function() return {} end,
	})
	local startup_result = check_startup()
	helpers.assert_not_nil(registered_owner)
	return {
		owner = registered_owner,
		timers = timers,
		probes = probes,
		prediction_calls = prediction_calls,
		startup_result = startup_result,
		check_startup = check_startup,
		get_prediction_state = function() return keymap.get_llm_enabled() end,
		get_saves = function() return saves end,
		get_menu_updates = function() return menu_updates end,
		state = state,
		set_epoch = function(value) epoch = value end,
		set_paused = function(value) paused = value == true end,
		set_stop_mode = function(value) stop_mode = value end,
		set_arm_failure = function(mode, delay, count)
			arm_mode = mode
			arm_fail_delay = delay
			arm_failures_left = count or 0
		end,
		set_prediction_mode = function(value) prediction_mode = value end,
		set_dispatch_mode = function(value) dispatch_mode = value end,
	}
end

local function fire_timer_delay(ctx, delay, first_index)
	for index = first_index or 1, #ctx.timers do
		local timer = ctx.timers[index]
		if timer.delay == delay then
			timer.fn()
			return index
		end
	end
	return nil
end

return {
	load_real_startup_owner = load_real_startup_owner,
	fire_timer_delay = fire_timer_delay,
}
