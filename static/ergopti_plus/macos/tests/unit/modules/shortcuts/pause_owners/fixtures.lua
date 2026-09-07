--- tests/unit/modules/shortcuts/pause_owners/fixtures.lua

--- ==============================================================================
--- MODULE: Pause Owner Inventory Fixture
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNER_IDS = {
	"mlx_dependency_bootstrap",
	"ollama_dependency_bootstrap",
	"mlx_model_maintenance",
	"ollama_model_maintenance",
	"llm_activation",
	"llm_model_switcher",
	"llm_startup",
	"keymap_processing",
	"shortcut_bindings",
	"gestures",
	"mlx_warmup",
	"warmup_controller",
	"ollama_warmup",
	"remote_warmup",
	"wpm_menubar",
	"wpm_widget",
	"remap_onboarding",
	"predictions",
	"tooltip",
}

local REVERSIBLE_OWNER_IDS = {
	"mlx_dependency_bootstrap",
	"ollama_dependency_bootstrap",
	"mlx_model_maintenance",
	"ollama_model_maintenance",
	"llm_activation",
	"llm_model_switcher",
	"llm_startup",
	"keymap_processing",
	"shortcut_bindings",
	"gestures",
	"mlx_warmup",
	"warmup_controller",
	"ollama_warmup",
	"remote_warmup",
	"wpm_menubar",
	"wpm_widget",
}

local function reset_module(name)
	package.loaded[name] = nil
end

--- Loads ScriptControl over an observable implementation of every inventory
--- owner. Each lifecycle method mutates first, then may false/nil/throw, proving
--- the transaction includes the failing mutator itself in rollback.
local function load_inventory_context(options)
	options = options or {}
	local ctx = {
		active = {},
		calls = {},
		late_effects = {},
		listeners = {},
		fail_owner = options.fail_owner,
		fail_mode = options.fail_mode,
		fail_direction = options.fail_direction or "pause",
		failures_left = options.fail_owner and 1 or 0,
		rollback_fail_owner = options.rollback_fail_owner,
		rollback_fail_mode = options.rollback_fail_mode,
		rollback_failures_left = options.rollback_fail_owner and 1 or 0,
		fence = nil,
	}
	for _, owner in ipairs(OWNER_IDS) do
		ctx.active[owner] = options.inactive_owner ~= owner
		ctx.calls[owner] = { pause = 0, resume = 0, release = 0 }
		ctx.late_effects[owner] = 0
	end

	local function invoke(owner, direction)
		return function()
			ctx.calls[owner][direction] = ctx.calls[owner][direction] + 1
			if direction == "resume" and ctx.rollback_failures_left > 0
				and ctx.rollback_fail_owner == owner then
				ctx.rollback_failures_left = ctx.rollback_failures_left - 1
				if ctx.rollback_fail_mode == "throw" then
					error(owner .. " rollback exploded")
				end
				if ctx.rollback_fail_mode == "false" then return false, "refused" end
				if ctx.rollback_fail_mode == "nil" then return nil end
			end
			local pause_owned_key = owner .. "_pause_owned"
			local was_active_key = owner .. "_was_active"
			if direction == "pause" then
				-- A refused inverse leaves the original pause snapshot owned. A
				-- retry must re-fence the same owner without replacing that intent
				-- with its already-quiesced live state.
				if ctx[pause_owned_key] ~= true then
					ctx[was_active_key] = ctx.active[owner] == true
					ctx[pause_owned_key] = true
				end
				ctx.active[owner] = false
			elseif ctx[was_active_key] == true then
				ctx.active[owner] = true
			end
			if direction == ctx.fail_direction and ctx.failures_left > 0
				and ctx.fail_owner == owner then
				ctx.failures_left = ctx.failures_left - 1
				if ctx.fail_mode == "throw" then error(owner .. " cleanup exploded") end
				if ctx.fail_mode == "false" then return false, "refused" end
				if ctx.fail_mode == "nil" then return nil end
			end
			if direction == "resume" then
				ctx[pause_owned_key] = nil
				ctx[was_active_key] = nil
			end
			return true
		end
	end

	local function late(owner)
		if ctx.active[owner] == true then
			ctx.late_effects[owner] = ctx.late_effects[owner] + 1
		end
	end
	ctx.fire_every_late_callback = function()
		for _, owner in ipairs(OWNER_IDS) do late(owner) end
	end

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 106,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE = 108,
		BACKSPACE = 51,
		RETURN = 36,
		ESCAPE = 53,
	}
	package.loaded["modules.gestures.engine"] = options.gesture_engine or {}
	package.loaded["modules.gestures.actions"] = options.gesture_actions or {
		get_label = function(name) return name end,
		execute_single = function() return true end,
		SG_NAMES = { "none", "script_pause_toggle" },
		AX_NAMES = {},
	}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	package.loaded["adapters.synthetic_input"] = {
		when_idle = options.when_idle or function(callback) callback(); return true end,
		acquire_admission_fence = function()
			if ctx.fence then return nil end
			ctx.fence = { active = true }
			return ctx.fence
		end,
		release_admission_fence = function(token)
			if type(options.release_admission_fence) == "function" then
				return options.release_admission_fence(token, ctx)
			end
			if token ~= ctx.fence or token.active ~= true then return false end
			token.active = false
			ctx.fence = nil
			return true
		end,
		admission_open = function() return ctx.fence == nil end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function() return { kind = "one-shot" }, true end,
		every = function() return { kind = "watchdog" }, true end,
		cancel = function() return true end,
	}
	package.loaded["modules.llm.api_mlx"] = {
		pause_warmup = invoke("mlx_warmup", "pause"),
		stop_warmup = invoke("mlx_warmup", "pause"),
		resume_warmup = invoke("mlx_warmup", "resume"),
	}
	package.loaded["modules.llm.warmup_controller"] = {
		pause_warmup = invoke("warmup_controller", "pause"),
		resume_warmup = invoke("warmup_controller", "resume"),
	}
	package.loaded["modules.llm.api_ollama"] = options.ollama or {
		pause_warmup = invoke("ollama_warmup", "pause"),
		resume_warmup = invoke("ollama_warmup", "resume"),
	}
	package.loaded["modules.llm.api_remote"] = options.remote or {
		pause_warmup = invoke("remote_warmup", "pause"),
		resume_warmup = invoke("remote_warmup", "resume"),
	}
	package.loaded["ui.wpm.wpm_menubar"] = {
		is_running = function() return ctx.active.wpm_menubar end,
		stop = invoke("wpm_menubar", "pause"),
		resume_after_pause = invoke("wpm_menubar", "resume"),
	}
	package.loaded["ui.wpm.wpm_widget"] = {
		is_running = function() return ctx.active.wpm_widget end,
		stop = invoke("wpm_widget", "pause"),
		resume_after_pause = invoke("wpm_widget", "resume"),
	}
	package.loaded["platform.remap.onboarding"] = {
		stop = invoke("remap_onboarding", "pause"),
	}
	package.loaded["ui.tooltip"] = {
		hide_forced = invoke("tooltip", "pause"),
	}
	package.loaded["modules.keylogger"] = {
		resync_context = function() return true end,
		log_shortcut = function() end,
	}

	local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
	local keymap = options.keymap or {
		pause_processing = invoke("keymap_processing", "pause"),
		resume_processing = invoke("keymap_processing", "resume"),
		reset_predictions = invoke("predictions", "pause"),
		reset_predictions_for_pause = invoke("predictions", "pause"),
	}
	local shortcuts = options.shortcuts or {
		is_bindings_started = function() return ctx.active.shortcut_bindings end,
		pause_bindings = invoke("shortcut_bindings", "pause"),
		resume_bindings = invoke("shortcut_bindings", "resume"),
		release_bindings_pause_claim = function()
			ctx.calls.shortcut_bindings.release = ctx.calls.shortcut_bindings.release + 1
			ctx.shortcut_bindings_pause_owned = nil
			ctx.shortcut_bindings_was_active = nil
			return true
		end,
	}
	local gestures = options.gestures or {
		is_enabled = function() return ctx.active.gestures end,
		suspend = invoke("gestures", "pause"),
		resume = invoke("gestures", "resume"),
	}
	for _, owner in ipairs({
		"mlx_dependency_bootstrap",
		"ollama_dependency_bootstrap",
		"mlx_model_maintenance",
		"ollama_model_maintenance",
		"llm_activation",
		"llm_model_switcher",
		"llm_startup",
	}) do
		local skipped = options.skip_dynamic_owner == owner
			or (type(options.skip_dynamic_owners) == "table"
				and options.skip_dynamic_owners[owner] == true)
		if not skipped then
			helpers.assert_true(script_control.register_pause_owner(owner, {
				pause = invoke(owner, "pause"),
				resume = invoke(owner, "resume"),
			}))
		end
	end
	helpers.assert_true(script_control.start(keymap, shortcuts, gestures, options.karabiner))
	script_control.set_on_pause_change(function(paused)
		ctx.listeners[#ctx.listeners + 1] = paused
	end)
	return script_control, ctx
end

local function get_upvalue(fn, target)
	for index = 1, 80 do
		local name, value = debug.getupvalue(fn, index)
		if not name then return nil end
		if name == target then return value end
	end
	return nil
end

return {
	OWNER_IDS = OWNER_IDS,
	REVERSIBLE_OWNER_IDS = REVERSIBLE_OWNER_IDS,
	reset_module = reset_module,
	load_inventory_context = load_inventory_context,
	get_upvalue = get_upvalue,
}
