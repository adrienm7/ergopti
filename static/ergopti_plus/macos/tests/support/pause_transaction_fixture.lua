--- tests/support/pause_transaction_fixture.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Transaction Fixture
--- DESCRIPTION:
--- Drives the real pause coordinator over observable subsystem doubles.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"modules.shortcuts.script_control",
	"infra.logger",
	"infra.notifications",
	"infra.keycodes",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"adapters.key_state",
	"adapters.synthetic_input",
	"modules.llm.warmup_controller",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"modules.keylogger",
	"adapters.event_provenance",
	"adapters.timer_scheduler",
}

--- Loads a fresh script-control module over observable subsystem doubles.
--- @param options table|nil Failure injection options.
--- @return table script_control
--- @return table ctx
local function load_context(options)
	options = options or {}
	local ctx = {
		calls = {},
		call_order = {},
		hooks = {},
		states = {
			keymap = true,
			shortcuts = true,
			gestures = true,
			mlx_warmup = true,
			warmup_controller = true,
			ollama_warmup = true,
			predictions = true,
			tooltip = true,
		},
		native_state = "running",
		notifications = {},
		errors = {},
		warnings = {},
		pause_callback = nil,
		pause_callbacks = {},
		resume_callback = nil,
		resume_callbacks = {},
		pause_listener = {},
		input_idle_callbacks = {},
		admission_fence = nil,
		admission_serial = 0,
		admission_release_tokens = {},
		admission_release_failures = options.admission_release_failures or 0,
		admission_release_throws = options.admission_release_throws or 0,
		pause_failure = options.pause_failure,
		resume_failure = options.resume_failure,
		snapshot_failure = options.snapshot_failure,
	}
	local state_changes = {
		keymap_pause = { "keymap", false },
		keymap_resume = { "keymap", true },
		shortcuts_pause = { "shortcuts", false },
		shortcuts_resume = { "shortcuts", true },
		gestures_pause = { "gestures", false },
		gestures_resume = { "gestures", true },
		mlx_stop = { "mlx_warmup", false },
		mlx_resume = { "mlx_warmup", true },
		warmup_stop = { "warmup_controller", false },
		warmup_resume = { "warmup_controller", true },
		ollama_stop = { "ollama_warmup", false },
		keymap_reset = { "predictions", false },
		tooltip_hide = { "tooltip", false },
	}

	local function record(name)
		return function()
			ctx.calls[name] = (ctx.calls[name] or 0) + 1
			ctx.call_order[#ctx.call_order + 1] = name
			local mutation = state_changes[name]
			if mutation then ctx.states[mutation[1]] = mutation[2] end
			local hook = ctx.hooks[name]
			if type(hook) == "function" then hook() end
			-- Failure is injected AFTER the mutation. A correct transaction must
			-- therefore include the failing operation itself in reverse rollback.
			local failure = ctx.pause_failure
			if not (failure and failure.step == name) then
				failure = ctx.resume_failure
			end
			if failure and failure.step == name then
				if failure.mode == "throw" then error(name .. " exploded") end
				if failure.mode == "false" then return false, name .. " refused" end
				if failure.mode == "nil" then return nil, name .. " returned nil" end
			end
			return true
		end
	end
	local function inverse(name)
		if options.missing_inverse == name then return nil end
		return record(name)
	end
	local function snapshot(name)
		return function()
			ctx.calls[name] = (ctx.calls[name] or 0) + 1
			local failure = ctx.snapshot_failure
			if failure and failure.step == name then
				if failure.mode == "throw" then error(name .. " exploded") end
				if failure.mode == "non_boolean" then return nil end
			end
			return true
		end
	end

	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		ctx.errors[#ctx.errors + 1] = string.format(format_string, ...)
	end
	logger.warn = function(_module, format_string, ...)
		ctx.warnings[#ctx.warnings + 1] = string.format(format_string, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			ctx.notifications[#ctx.notifications + 1] = {
				title = title,
				body = body,
				kind = kind,
			}
		end,
	}
	package.loaded["infra.keycodes"] = {
		F13_KARABINER_RETURN = 0x6A,
		F14_KARABINER_BACKSPACE = 0x6B,
		F15_KARABINER_ESCAPE = 0x6C,
		BACKSPACE = 0x33,
		RETURN = 0x24,
		ESCAPE = 0x35,
	}
	package.loaded["modules.gestures.engine"] = {}
	package.loaded["modules.gestures.actions"] = {
		get_label = function(name) return name end,
		execute_single = function() return true end,
		SG_NAMES = { "none", "script_pause_toggle" },
		AX_NAMES = {},
	}
	package.loaded["adapters.key_state"] = {
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	}
	package.loaded["modules.llm.warmup_controller"] = {
		pause_warmup = record("warmup_stop"),
		resume_warmup = inverse("warmup_resume"),
	}
	package.loaded["modules.llm.api_mlx"] = {
		stop_warmup = record("mlx_stop"),
		resume_warmup = inverse("mlx_resume"),
	}
	package.loaded["modules.llm.api_ollama"] = {
		stop_warmup = record("ollama_stop"),
	}
	-- HS-012 added these fixed pause owners. Keep this older transaction harness
	-- independent from whichever real/cache-backed instance a prior test loaded;
	-- the class-wide owner matrix exercises their refusal paths separately.
	package.loaded["modules.llm.api_remote"] = {
		stop_warmup = function() return true end,
	}
	package.loaded["ui.wpm.wpm_menubar"] = {
		is_running = function() return false end,
		stop = function() return true end,
		resume_after_pause = function() return true end,
	}
	package.loaded["ui.wpm.wpm_widget"] = {
		is_running = function() return false end,
		stop = function() return true end,
		resume_after_pause = function() return true end,
	}
	package.loaded["platform.remap.onboarding"] = {
		stop = function() return true end,
	}
	package.loaded["ui.tooltip"] = { hide_forced = record("tooltip_hide") }
	package.loaded["modules.keylogger"] = {
		resync_context = record("keylogger_resync"),
		log_shortcut = function() end,
	}
	package.loaded["adapters.synthetic_input"] = {
		when_idle = function(callback)
			ctx.calls.input_drain = (ctx.calls.input_drain or 0) + 1
			ctx.input_idle_callbacks[#ctx.input_idle_callbacks + 1] = callback
			if options.input_drain_deferred ~= true then callback() end
			return options.input_drain_accepted ~= false
		end,
		acquire_admission_fence = function(owner)
			ctx.calls.admission_acquire = (ctx.calls.admission_acquire or 0) + 1
			if options.admission_refused == true or ctx.admission_fence ~= nil then return nil end
			ctx.admission_serial = ctx.admission_serial + 1
			local token = { id = ctx.admission_serial, owner = owner, active = true }
			ctx.admission_fence = token
			return token
		end,
		release_admission_fence = function(token)
			ctx.calls.admission_release = (ctx.calls.admission_release or 0) + 1
			ctx.admission_release_tokens[#ctx.admission_release_tokens + 1] = token
			if ctx.admission_release_throws > 0 then
				ctx.admission_release_throws = ctx.admission_release_throws - 1
				error("admission release exploded")
			end
			if ctx.admission_release_failures > 0 then
				ctx.admission_release_failures = ctx.admission_release_failures - 1
				return false
			end
			if token ~= ctx.admission_fence or token.active ~= true then return false end
			token.active = false
			ctx.admission_fence = nil
			return true
		end,
		admission_open = function() return ctx.admission_fence == nil end,
	}

	local script_control = helpers.load_with_stubs("modules.shortcuts.script_control")
	local keymap = {
		pause_processing = record("keymap_pause"),
		resume_processing = inverse("keymap_resume"),
		reset_predictions = record("keymap_reset"),
	}
	local shortcuts = {
		pause_bindings = record("shortcuts_pause"),
		resume_bindings = inverse("shortcuts_resume"),
		release_bindings_pause_claim = record("shortcuts_release_claim"),
		is_bindings_started = snapshot("shortcuts_snapshot"),
	}
	if type(options.shortcuts_factory) == "function" then
		shortcuts = options.shortcuts_factory(ctx, record, inverse, snapshot)
	end
	local gestures = {
		suspend = record("gestures_pause"),
		resume = inverse("gestures_resume"),
		is_enabled = snapshot("gestures_snapshot"),
	}
	local get_enabled = function()
			if options.get_enabled_throws then error("get_enabled exploded") end
			if options.get_enabled_mode == "nil" then return nil end
			if options.get_enabled_mode == "non_boolean" then return "enabled" end
			return options.integration_enabled ~= false
		end
	if options.get_enabled_missing then get_enabled = nil end
	local karabiner = {
		get_enabled = get_enabled,
		pause = function(callback)
			ctx.calls.karabiner_pause = (ctx.calls.karabiner_pause or 0) + 1
			local callback_fired = false
			local function wrapped_callback(ok, reason)
				if not callback_fired then
					callback_fired = true
					if ok == true then ctx.native_state = "paused" end
				end
				callback(ok, reason)
			end
			ctx.pause_callback = wrapped_callback
			ctx.pause_callbacks[#ctx.pause_callbacks + 1] = wrapped_callback
			return true
		end,
		resume = function(callback)
			ctx.calls.karabiner_resume = (ctx.calls.karabiner_resume or 0) + 1
			local callback_fired = false
			local function wrapped_callback(ok, reason)
				if not callback_fired then
					callback_fired = true
					if ok == true then ctx.native_state = "running" end
				end
				callback(ok, reason)
			end
			ctx.resume_callback = wrapped_callback
			ctx.resume_callbacks[#ctx.resume_callbacks + 1] = wrapped_callback
			return true
		end,
	}

	if options.no_integration then karabiner = nil end
	script_control.start(keymap, shortcuts, gestures, karabiner)
	script_control.set_on_pause_change(function(value)
		ctx.pause_listener[#ctx.pause_listener + 1] = value
	end)

	--- Fires only live one-shot zero-delay work, never the recurring tap watchdog.
	function ctx.fire_deferred()
		for _, timer in ipairs(hs.timer.__timers) do
			if timer.delay == 0 and timer.recurring ~= true and timer.running then timer:fire() end
		end
	end

	return script_control, ctx
end

--- Runs construction and all transaction callbacks inside the fixture lifetime.
--- @param options table|nil Failure injection options.
--- @param callback function Receives script control and its observable context.
--- @return ... Callback results.
function M.with_context(options, callback)
	return helpers.with_stub_scope(OWNERS, function()
		return callback(load_context(options))
	end)
end

return M
