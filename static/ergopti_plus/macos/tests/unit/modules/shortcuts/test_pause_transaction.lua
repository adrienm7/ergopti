--- tests/unit/modules/shortcuts/test_pause_transaction.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Transaction Regression Tests
--- DESCRIPTION:
--- Drives the public pause/resume API across the script-control and Karabiner
--- boundary. Pause commits after PAUSED; resume commits only after the remap
--- layer reports RESUMED, publication, READY and input startup complete. Failed
--- or duplicated callbacks must never create a half-resumed driver.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Transaction Test Harness =======
-- ===========================================
-- ===========================================

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

local function count_notifications(ctx, title, kind)
	local count = 0
	for _, item in ipairs(ctx.notifications) do
		if item.title == title and item.kind == kind then count = count + 1 end
	end
	return count
end

local function has_error_containing(ctx, needle)
	for _, message in ipairs(ctx.errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function has_warning_containing(ctx, needle)
	for _, message in ipairs(ctx.warnings) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function assert_reversible_modules_running(ctx, context)
	for _, name in ipairs({
		"keymap", "shortcuts", "gestures", "mlx_warmup", "warmup_controller",
	}) do
		helpers.assert_eq(ctx.states[name], true,
			string.format("%s: reversible module '%s' must be restored", context, name))
	end
end





-- ===========================================
-- ===========================================
-- ======= 2/ ACK-Ordered Pause Commit =======
-- ===========================================
-- ===========================================

helpers.describe("script-control pause transaction waits for exact lease ACK", function()
	helpers.it("keeps every feature live until paced input is idle and cancels a queued reversal", function()
		local script_control, ctx = load_context({ input_drain_deferred = true })

		helpers.assert_true(script_control.pause_all())
		helpers.assert_eq(ctx.calls.input_drain, 1)
		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_pause, nil,
			"native pause must not overtake an owned paced replacement")
		helpers.assert_eq(ctx.calls.keymap_pause, nil)
		helpers.assert_eq(script_control.is_paused(), false)

		helpers.assert_true(script_control.resume_all(),
			"a rapid reversal must be accepted while the input drain owns pause")
		ctx.input_idle_callbacks[1]()
		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_pause, nil,
			"the queued resume must cancel pause before native publication")
		helpers.assert_eq(ctx.calls.keymap_pause, nil)
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_nil(ctx.admission_fence,
			"a queued resume cancels pause before taking the admission fence")
		script_control.stop()
	end)

	helpers.it("does not publish or quiesce pause before PAUSED, then commits once", function()
		local script_control, ctx = load_context()

		script_control.pause_all()
		helpers.assert_not_nil(ctx.admission_fence,
			"the idle callback must close admission before native PAUSED is requested")
		helpers.assert_eq(script_control.is_paused(), false,
			"requesting pause must not publish a committed state")
		helpers.assert_eq(ctx.calls.karabiner_pause, nil,
			"the native transition request must be deferred off the caller/eventtap")
		helpers.assert_eq(ctx.calls.keymap_pause, nil,
			"Hammerspoon submodules must remain in their settled state before PAUSED")
		helpers.assert_eq(#ctx.pause_listener, 0, "listeners must wait for the exact ACK")
		helpers.assert_eq(#ctx.notifications, 0, "success notification must wait for the exact ACK")

		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_pause, 1)
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.keymap_pause, nil)

		ctx.pause_callback(true, "paused")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(ctx.calls.keymap_pause, 1)
		helpers.assert_eq(ctx.calls.shortcuts_pause, 1)
		helpers.assert_eq(ctx.calls.gestures_pause, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
		helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
		helpers.assert_not_nil(ctx.admission_fence,
			"committed pause retains the same admission owner until resume")

		ctx.pause_callback(true, "duplicate-paused")
		helpers.assert_eq(ctx.calls.keymap_pause, 1,
			"a duplicated native callback must not commit the pause twice")
		helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
		script_control.stop()
	end)
end)

helpers.describe("script-control: bindings child cleanup debt", function()
	helpers.it("settles pixel debt while preserving an originally OFF bindings layer", function()
		local calls = { pause = 0, resume = 0 }
		local debt = true
		local script_control, ctx = load_context({
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return false end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						return true
					end,
					release_bindings_pause_claim = function() return true end,
				}
			end,
		})

		helpers.assert_eq(script_control.pause_all(), true)
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(calls.pause, 1)
		helpers.assert_eq(debt, false)

		helpers.assert_eq(script_control.resume_all(), true)
		ctx.fire_deferred()
		ctx.resume_callback(true, "resumed")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(calls.resume, 0,
			"cleanup-only debt must not resurrect bindings that were OFF before pause")
		script_control.stop()
	end)

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("rejects an ambiguous bindings-debt snapshot after " .. mode, function()
			local pause_calls = 0
			local script_control, ctx = load_context({
				shortcuts_factory = function()
					return {
						is_bindings_started = function() return false end,
						has_bindings_pause_debt = function()
							if mode == "throw" then error("synthetic debt query failure") end
							return nil
						end,
						pause_bindings = function()
							pause_calls = pause_calls + 1
							return true
						end,
						resume_bindings = function() return true end,
						release_bindings_pause_claim = function() return true end,
					}
				end,
			})

			helpers.assert_eq(script_control.pause_all(), true,
				"the public request reports controller admission, not local settlement")
			ctx.fire_deferred()
			ctx.pause_callback(true, "native-paused")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(pause_calls, 0,
				"an ambiguous ownership query must fail before cleanup mutation")
			helpers.assert_eq(ctx.calls.karabiner_resume, 1,
				"the already-paused native layer must be rolled back")
			ctx.resume_callback(true, "native-running")
			script_control.stop()
		end)
	end

	helpers.it("does not duplicate a reversible shortcut debt with cleanup-only work", function()
		local calls = { pause = 0, resume = 0 }
		local started = true
		local debt = false
		local rollback_refusals = 1
		local script_control, ctx = load_context({
			pause_failure = { step = "mlx_stop", mode = "false" },
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return started end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						started = false
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						if rollback_refusals > 0 then
							rollback_refusals = rollback_refusals - 1
							debt = true
							return false
						end
						started = true
						debt = false
						return true
					end,
				}
			end,
		})

		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "first-native-paused")
		helpers.assert_eq(calls.pause, 1)
		helpers.assert_eq(calls.resume, 1)
		helpers.assert_eq(debt, true)
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		ctx.resume_callback(true, "first-native-rollback")

		ctx.pause_failure = nil
		helpers.assert_eq(script_control.pause_all(), true)
		ctx.fire_deferred()
		ctx.pause_callback(true, "retry-native-paused")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(calls.pause, 2,
			"the retained reversible owner must be quiesced once, not once per debt label")

		script_control.resume_all()
		ctx.fire_deferred()
		ctx.resume_callback(true, "final-native-resumed")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(calls.resume, 2)
		helpers.assert_eq(started, true,
			"the original ON intent must survive the retained reversible debt")
		script_control.stop()
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 3/ Pause Failure Is Atomic ========
-- ===========================================
-- ===========================================

helpers.describe("script-control pause transaction is atomic", function()
	helpers.it("rolls an originally-OFF shortcut claim back without starting children", function()
		local calls = { pause = 0, release = 0, resume = 0 }
		local script_control, ctx = load_context({
			pause_failure = { step = "gestures_pause", mode = "false" },
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return false end,
					pause_bindings = function(parent)
						helpers.assert_eq(parent, "script_control")
						calls.pause = calls.pause + 1
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						return true
					end,
					release_bindings_pause_claim = function(parent)
						helpers.assert_eq(parent, "script_control")
						calls.release = calls.release + 1
						return true
					end,
				}
			end,
		})

		helpers.assert_eq(script_control.pause_all(), true)
		ctx.fire_deferred()
		ctx.pause_callback(true, "native-paused")
		helpers.assert_eq(calls.pause, 1)
		helpers.assert_eq(calls.release, 1,
			"failed PAUSE must release only the OFF snapshot's global claim")
		helpers.assert_eq(calls.resume, 0,
			"rollback must not manufacture a shortcut ON transition")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		ctx.resume_callback(true, "native-running")
		script_control.stop()
	end)

	local pause_steps = {
		{ step = "keymap_pause", label = "keymap.pause_processing", rollback = "keymap_resume" },
		{ step = "shortcuts_pause", label = "shortcuts.pause_bindings", rollback = "shortcuts_resume" },
		{ step = "gestures_pause", label = "gestures.suspend", rollback = "gestures_resume" },
		{ step = "mlx_stop", label = "api_mlx.stop_warmup", rollback = "mlx_resume" },
		{ step = "warmup_stop", label = "warmup_controller.pause_warmup", rollback = "warmup_resume" },
		-- These three operations deliberately have no inverse. Re-opening a stale
		-- prediction/tooltip is unsafe, and Ollama stop_warmup only invalidates one
		-- in-flight generation without disabling readiness or a retry chain. They
		-- remain REQUIRED, however: a throw/false must still abort PAUSED and roll
		-- every reversible module back to its exact pre-pause state.
		{ step = "ollama_stop", label = "api_ollama.stop_warmup" },
		{ step = "keymap_reset", label = "keymap.reset_predictions" },
		{ step = "tooltip_hide", label = "tooltip.hide_forced" },
	}

	helpers.it("reopens admission only after a refused native pause settles", function()
		local script_control, ctx = load_context()
		helpers.assert_true(script_control.pause_all())
		helpers.assert_not_nil(ctx.admission_fence)
		ctx.fire_deferred()
		ctx.pause_callback(false, "native pause refused")

		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_nil(ctx.admission_fence,
			"failed PAUSED acknowledgement must roll admission back exactly")
		helpers.assert_eq(ctx.calls.admission_release, 1)
		helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
		script_control.stop()
	end)

	helpers.it("fails closed when the Karabiner enabled-state probe is not boolean", function()
		for _, mode in ipairs({ "nil", "non_boolean" }) do
			local script_control, ctx = load_context({ get_enabled_mode = mode })
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(#ctx.call_order, 0,
				"an ambiguous native snapshot may not mutate local owners")
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"an ambiguous native snapshot may not dispatch a transition")
			helpers.assert_eq(ctx.calls.admission_release, 1)
			helpers.assert_nil(ctx.admission_fence,
				"a clean preflight refusal must release the exact admission fence")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
			helpers.assert_eq(count_notifications(ctx,
				"script_control.pause_failed", "error"), 1)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("reuses a retained preflight fence on the next explicit pause", function()
		local cases = {
			{
				name = "false",
				options = { get_enabled_throws = true, admission_release_failures = 1 },
			},
			{
				name = "throw",
				options = { get_enabled_throws = true, admission_release_throws = 1 },
			},
			{
				name = "nil probe / false release",
				options = { get_enabled_mode = "nil", admission_release_failures = 1 },
			},
			{
				name = "non-boolean probe / throw release",
				options = { get_enabled_mode = "non_boolean", admission_release_throws = 1 },
			},
		}
		for _, case in ipairs(cases) do
			local script_control, ctx = load_context(case.options)
			helpers.assert_true(script_control.pause_all())
			local exact_fence = ctx.admission_fence
			helpers.assert_not_nil(exact_fence,
				case.name .. " release refusal must retain the acquired fence")
			helpers.assert_eq(ctx.calls.admission_release, 1,
				"preflight failure must attempt exact rollback immediately")
			helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
			helpers.assert_eq(count_notifications(ctx,
				"script_control.pause_failed", "error"), 1)

			case.options.get_enabled_throws = false
			case.options.get_enabled_mode = nil
			helpers.assert_true(script_control.pause_all(),
				case.name .. " retained fence must keep explicit pause retry reachable")
			helpers.assert_eq(ctx.calls.input_drain, 1,
				"the exact retained fence already owns the idle-to-PAUSED boundary")
			helpers.assert_eq(ctx.calls.admission_acquire, 1,
				"retry must never request a second fence while the first remains active")
			helpers.assert_true(ctx.admission_fence == exact_fence)
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			ctx.pause_callback(true, "retry-paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_true(ctx.admission_fence == exact_fence,
				"successful PAUSED commit retains the same fence until resume")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			helpers.assert_eq(count_notifications(ctx,
				"script_control.paused", "warning"), 1)
			helpers.assert_eq(count_notifications(ctx,
				"script_control.pause_failed", "error"), 1,
				"the successful retry must not republish the prior failure")
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("rolls every partial local pause back before publishing any PAUSED state", function()
		for _, mode in ipairs({ "throw", "false" }) do
			for failed_index, failed_step in ipairs(pause_steps) do
				local script_control, ctx = load_context({
					pause_failure = { step = failed_step.step, mode = mode },
				})

				script_control.pause_all()
				ctx.fire_deferred()
				local pause_order_start = #ctx.call_order + 1
				ctx.pause_callbacks[1](true, "paused")

				helpers.assert_eq(script_control.is_paused(), false,
					mode .. " from " .. failed_step.step .. " must preserve the running state")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"a partial local pause must immediately request native RESUMED rollback")
				helpers.assert_eq(ctx.native_state, "paused",
					"the rollback must remain pending until native RESUMED is acknowledged")
				helpers.assert_not_nil(ctx.admission_fence,
					"local pause failure must keep admission closed through native rollback")
				helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0,
					"partial local pause must never publish PAUSED")
				helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 0,
					"failure must remain unpublished until native rollback settles")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}),
					"listeners must never observe the uncommitted PAUSED state")
				assert_reversible_modules_running(ctx, mode .. " from " .. failed_step.step)

				local expected_order = {}
				for step_index = 1, failed_index do
					expected_order[#expected_order + 1] = pause_steps[step_index].step
				end
				for step_index = failed_index, 1, -1 do
					local rollback = pause_steps[step_index].rollback
					if rollback then expected_order[#expected_order + 1] = rollback end
				end
				local actual_order = {}
				for index = pause_order_start, #ctx.call_order do
					actual_order[#actual_order + 1] = ctx.call_order[index]
				end
				helpers.assert_true(helpers.deep_equal(actual_order, expected_order),
					"pause rollback must include the failing mutator and invert in reverse order")

				local failed_attempts = ctx.calls[failed_step.step]
				ctx.pause_callbacks[1](true, "duplicate-paused")
				helpers.assert_eq(ctx.calls[failed_step.step], failed_attempts,
					"a duplicate PAUSED callback must not re-enter local quiescence during rollback")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"a duplicate PAUSED callback must not request another native rollback")

				ctx.resume_callbacks[1](true, "running-restored")
				helpers.assert_eq(ctx.native_state, "running")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_nil(ctx.admission_fence,
					"only the settled RESUMED rollback may reopen admission")
				helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1,
					"pause failure may be published only after native RESUMED")
				helpers.assert_true(has_error_containing(ctx, failed_step.label),
					"the root failing pause step must be named in the file logger")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))

				ctx.pause_failure = nil
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[2](true, "retry-paused")
				helpers.assert_eq(script_control.is_paused(), true,
					"a clean retry after rollback must remain reachable")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
				helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
				script_control.stop()
			end
		end
	end)

	helpers.it("preflights inverse APIs before mutating the first pause subsystem", function()
		local cases = {
			{ inverse = "keymap_resume", label = "keymap.pause_processing" },
			{ inverse = "shortcuts_resume", label = "shortcuts.pause_bindings" },
			{ inverse = "gestures_resume", label = "gestures.suspend" },
			{ inverse = "mlx_resume", label = "api_mlx.stop_warmup" },
			{ inverse = "warmup_resume", label = "warmup_controller.pause_warmup" },
		}
		for _, case in ipairs(cases) do
			local script_control, ctx = load_context({ missing_inverse = case.inverse })
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")

			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(#ctx.call_order, 0,
				"every inverse must be preflighted before the first forward mutator runs")
			helpers.assert_eq(ctx.calls.karabiner_resume, 1,
				"native PAUSED must be rolled back after local preflight failure")
			ctx.resume_callbacks[1](true, "running-restored")
			helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
			helpers.assert_true(has_error_containing(ctx, case.label .. " has no inverse rollback"))
			assert_reversible_modules_running(ctx, "missing inverse preflight: " .. case.inverse)
			script_control.stop()
		end
	end)

	helpers.it("contains snapshot errors before any pause mutator can run", function()
		local cases = {
			{ step = "shortcuts_snapshot", label = "shortcuts.is_bindings_started" },
			{ step = "gestures_snapshot", label = "gestures.is_enabled" },
		}
		for _, mode in ipairs({ "throw", "non_boolean" }) do
			for _, case in ipairs(cases) do
				local script_control, ctx = load_context({
					snapshot_failure = { step = case.step, mode = mode },
				})
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(#ctx.call_order, 0,
					"snapshot failure must happen before the first quiescence mutator")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1)
				helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0)
				ctx.resume_callbacks[1](true, "running-restored")
				helpers.assert_true(has_error_containing(ctx, case.label),
					"the failing snapshot must be named in the file logger")
				helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
				assert_reversible_modules_running(ctx, mode .. " snapshot: " .. case.step)
				script_control.stop()
			end
		end
	end)

	helpers.it("never invents PAUSED when native rollback settles fail-closed", function()
		local script_control, ctx = load_context({
			pause_failure = { step = "keymap_pause", mode = "false" },
		})
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callbacks[1](true, "paused")
		ctx.resume_callbacks[1](false, "resume-failed-closed")

		helpers.assert_eq(ctx.native_state, "paused",
			"failed native rollback must remain honestly modelled as PAUSED")
		helpers.assert_eq(script_control.is_paused(), false,
			"local quiescence failed, so script-control must not invent a PAUSED commit")
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
		helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0)
		helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
		assert_reversible_modules_running(ctx, "fail-closed native rollback")

		ctx.pause_failure = nil
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callbacks[2](true, "retry-paused")
		helpers.assert_eq(script_control.is_paused(), true,
			"the known native PAUSED state must permit a clean local pause retry")
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
		script_control.stop()
	end)
end)





-- ============================================
-- ============================================
-- ======= 4/ Resume Failure Is Atomic ========
-- ============================================
-- ============================================

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("keeps PAUSED ownership when the Karabiner resume snapshot is ambiguous", function()
		for _, mode in ipairs({ "nil", "non_boolean" }) do
			local options = {}
			local script_control, ctx = load_context(options)
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			local exact_fence = ctx.admission_fence
			local committed_calls = #ctx.call_order

			options.get_enabled_mode = mode
			helpers.assert_eq(script_control.resume_all(), false)
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_true(ctx.admission_fence == exact_fence,
				"ambiguous native state must retain the exact PAUSED admission fence")
			helpers.assert_eq(#ctx.call_order, committed_calls,
				"ambiguous native state may not resume a local owner")
			helpers.assert_eq(ctx.calls.karabiner_resume, nil,
				"ambiguous native state may not dispatch native RESUME")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

			options.get_enabled_mode = nil
			helpers.assert_true(script_control.resume_all())
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("keeps pause and resumes zero Hammerspoon modules when RESUMED fails", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")

		script_control.resume_all()
		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		helpers.assert_eq(script_control.is_paused(), true,
			"resume request must keep the last ACKed pause state")
		helpers.assert_eq(ctx.calls.keymap_resume, nil)
		helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
		helpers.assert_eq(ctx.calls.gestures_resume, nil)

		ctx.resume_callback(false, "cli-failed")
		helpers.assert_eq(script_control.is_paused(), true,
			"a failed CLI transition must leave the script fully paused")
		helpers.assert_eq(ctx.calls.keymap_resume, nil,
			"failure must resume zero Hammerspoon submodules")
		helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
		helpers.assert_eq(ctx.calls.gestures_resume, nil)
		helpers.assert_true(#ctx.errors >= 1, "the failure must be logged")
		helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
			"the user must see a non-blocking failure notification")
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
			"no resume listener may fire for a failed transition")
		script_control.stop()
	end)

	helpers.it("commits a successful completed-resume callback exactly once", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")
		helpers.assert_not_nil(ctx.admission_fence)

		script_control.resume_all()
		ctx.fire_deferred()
		ctx.resume_callback(true, "resumed")
		ctx.resume_callback(true, "duplicate-resumed")

		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_nil(ctx.admission_fence,
			"RESUMED plus local activation is the exact admission reopen point")
		helpers.assert_eq(ctx.calls.admission_release, 1)
		helpers.assert_eq(ctx.calls.keymap_resume, 1)
		helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
		helpers.assert_eq(ctx.calls.gestures_resume, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
		helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
		script_control.stop()
	end)

	helpers.it("never publishes RESUMED before exact admission release settles", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local options = mode == "false"
				and { admission_release_failures = 1 }
				or { admission_release_throws = 1 }
			local script_control, ctx = load_context(options)
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			local exact_fence = ctx.admission_fence

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), true,
				mode .. " admission release must roll local activation back to PAUSED")
			helpers.assert_true(ctx.admission_fence == exact_fence,
				"the exact refused fence remains owned for retry")
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
				"listeners may not observe RESUMED before admission reopens")
			helpers.assert_eq(ctx.calls.karabiner_pause, 2,
				"native RESUMED must be rolled back when admission cannot reopen")

			ctx.pause_callbacks[2](true, "re-paused")
			helpers.assert_true(ctx.admission_fence == exact_fence)
			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callbacks[2](true, "retry-resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
			script_control.stop()
		end
	end)

	helpers.it("keeps no-integration resume private until the exact fence releases", function()
		local script_control, ctx = load_context({
			integration_enabled = false,
			admission_release_failures = 1,
		})
		script_control.pause_all()
		local exact_fence = ctx.admission_fence
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

		script_control.resume_all()
		helpers.assert_eq(script_control.is_paused(), true,
			"local-only resume must roll back when admission release returns false")
		helpers.assert_true(ctx.admission_fence == exact_fence)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
		helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)

		script_control.resume_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_nil(ctx.admission_fence)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
		script_control.stop()
	end)

	helpers.it("stop retains and retries an exact admission release refusal", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		ctx.fire_deferred()
		ctx.pause_callback(true, "paused")
		local exact_fence = ctx.admission_fence
		ctx.admission_release_throws = 1

		helpers.assert_true(not script_control.stop(),
			"stop cannot report settlement while admission remains fenced")
		helpers.assert_true(ctx.admission_fence == exact_fence)
		helpers.assert_true(exact_fence.active)
		helpers.assert_true(script_control.stop(),
			"a later stop must retry the same retained fence")
		helpers.assert_nil(ctx.admission_fence)
		helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
		helpers.assert_true(ctx.admission_release_tokens[2] == exact_fence)
	end)

	helpers.it("joins an already-dispatched native transition before stopping", function()
		-- PAUSE direction: the exact admission fence and callback must survive stop.
		do
			local script_control, ctx = load_context()
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			local exact_fence = ctx.admission_fence
			helpers.assert_eq(script_control.stop(), false,
				"stop cannot discard a dispatched native PAUSE owner")
			helpers.assert_true(script_control.is_pause_transition_pending())
			helpers.assert_true(ctx.admission_fence == exact_fence)
			helpers.assert_eq(ctx.calls.admission_release, nil)

			ctx.pause_callbacks[1](true, "paused-after-stop-refusal")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_true(script_control.stop(),
				"terminal native ownership must make the later stop reachable")
			ctx.pause_callbacks[1](true, "duplicate-paused")
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
		end

		-- RESUME direction: stop may not release the fence ahead of native RESUMED.
		do
			local script_control, ctx = load_context()
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")
			local exact_fence = ctx.admission_fence
			helpers.assert_true(script_control.resume_all())
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			helpers.assert_eq(script_control.stop(), false,
				"stop cannot discard a dispatched native RESUME owner")
			helpers.assert_true(script_control.is_pause_transition_pending())
			helpers.assert_true(ctx.admission_fence == exact_fence)
			helpers.assert_eq(ctx.calls.admission_release, nil)

			ctx.resume_callbacks[1](true, "resumed-after-stop-refusal")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_true(script_control.stop())
			ctx.resume_callbacks[1](true, "duplicate-resumed")
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
		end
	end)

	helpers.it("queues the original target again while native rollback is pending", function()
		-- A PAUSE whose local half fails is already destined back to ACTIVE. A new
		-- PAUSE request during that native rollback must survive as a fresh attempt.
		do
			local script_control, ctx = load_context()
			ctx.pause_failure = { step = "shortcuts_pause", mode = "false" }
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "native-paused")
			helpers.assert_eq(ctx.calls.karabiner_resume, 1,
				"local PAUSE refusal must own native ACTIVE rollback")
			helpers.assert_true(script_control.pause_all(),
				"same target during rollback must be queued, not mistaken for satisfaction")
			ctx.pause_failure = nil
			ctx.resume_callbacks[1](true, "native-running")
			helpers.assert_true(script_control.is_pause_transition_pending(),
				"terminal rollback must dispatch the queued PAUSE")
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, 2)
			ctx.pause_callbacks[2](true, "retry-paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_true(script_control.stop())
		end

		-- Symmetric RESUME retry while the failed activation is being re-paused.
		do
			local script_control, ctx = load_context()
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")
			ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
			helpers.assert_true(script_control.resume_all())
			ctx.fire_deferred()
			ctx.resume_callbacks[1](true, "native-resumed")
			helpers.assert_eq(ctx.calls.karabiner_pause, 2,
				"local RESUME refusal must own native PAUSED rollback")
			helpers.assert_true(script_control.resume_all(),
				"same target during rollback must be retained as latest intent")
			ctx.resume_failure = nil
			ctx.pause_callbacks[2](true, "native-repaused")
			helpers.assert_true(script_control.is_pause_transition_pending(),
				"terminal rollback must dispatch the queued RESUME")
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_resume, 2)
			ctx.resume_callbacks[2](true, "retry-resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("rolls every partial local resume back before publishing any failure", function()
		local resume_steps = {
			{ step = "keymap_resume", label = "keymap.resume_processing", rollback = "keymap_pause" },
			{ step = "shortcuts_resume", label = "shortcuts.resume_bindings", rollback = "shortcuts_pause" },
			{ step = "gestures_resume", label = "gestures.resume", rollback = "gestures_pause" },
			{ step = "mlx_resume", label = "api_mlx.resume_warmup", rollback = "mlx_stop" },
			{ step = "warmup_resume", label = "warmup_controller.resume_warmup", rollback = "warmup_stop" },
		}
		local failure_modes = { "throw", "false" }

		for _, mode in ipairs(failure_modes) do
			for failed_index, failed_step in ipairs(resume_steps) do
				local script_control, ctx = load_context({
					resume_failure = { step = failed_step.step, mode = mode },
				})
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				script_control.resume_all()
				ctx.fire_deferred()
				local resume_order_start = #ctx.call_order + 1
				ctx.resume_callback(true, "resumed")

				helpers.assert_eq(script_control.is_paused(), true,
					mode .. " from " .. failed_step.step .. " must preserve the committed pause state")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"a partial local resume must immediately request a native re-pause")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0,
					"partial local resume must never publish success")
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0,
					"failure must remain unpublished until the native re-pause is acknowledged")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
					"listeners must keep observing pause throughout local rollback")
				local failed_attempts = ctx.calls[failed_step.step]
				ctx.resume_callback(true, "duplicate-resumed")
				helpers.assert_eq(ctx.calls[failed_step.step], failed_attempts,
					"a duplicate RESUMED callback must not re-enter local activation during native rollback")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"a duplicate RESUMED callback must not request a second rollback")

				for step_index, step in ipairs(resume_steps) do
					if step.rollback then
						local expected = step_index <= failed_index and 2 or 1
						helpers.assert_eq(ctx.calls[step.rollback], expected,
							step.rollback .. " must be the exact inverse for " .. failed_step.step)
					end
				end
				local expected_order = {}
				for step_index = 1, failed_index do
					expected_order[#expected_order + 1] = resume_steps[step_index].step
				end
				for step_index = failed_index, 1, -1 do
					expected_order[#expected_order + 1] = resume_steps[step_index].rollback
				end
				local actual_order = {}
				for index = resume_order_start, #ctx.call_order do
					actual_order[#actual_order + 1] = ctx.call_order[index]
				end
				helpers.assert_true(helpers.deep_equal(actual_order, expected_order),
					"rollback must apply exact inverses in reverse activation order")

				ctx.pause_callbacks[2](true, "re-paused")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
					"failure may be published only after native PAUSED")
				helpers.assert_true(has_error_containing(ctx, failed_step.label),
					"the root failing resume step must be named in the file logger")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

				ctx.resume_failure = nil
				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false,
					"a clean retry after rollback must remain reachable")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
				script_control.stop()
			end
		end
	end)

	helpers.it("retains local re-pause debt until the same-state PAUSE settles it", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local script_control, ctx = load_context({ no_integration = true })
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)

			ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
			ctx.pause_failure = { step = "shortcuts_pause", mode = mode }
			helpers.assert_eq(script_control.resume_all(), false,
				mode .. " re-pause refusal must abort the local resume")
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.is_pause_transition_pending(),
				"terminal request state must retain the exact local rollback debt")
			helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
			helpers.assert_eq(ctx.calls.shortcuts_pause, 2,
				"initial pause plus failed rollback must target the same owner")

			helpers.assert_eq(script_control.pause_all(), false,
				"PAUSE while already PAUSED must retry the retained local inverse")
			helpers.assert_eq(ctx.calls.shortcuts_pause, 3)
			helpers.assert_eq(ctx.calls.shortcuts_resume, 1,
				"debt settlement may not acquire a resume successor")
			helpers.assert_true(script_control.is_pause_transition_pending())

			ctx.pause_failure = nil
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(ctx.calls.shortcuts_pause, 4)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false,
				"literal re-pause settlement must consume the debt")
			ctx.resume_failure = nil
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("keeps re-pause debt visible after the native rollback callback", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local script_control, ctx = load_context()
			helpers.assert_true(script_control.pause_all())
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")

			ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
			ctx.pause_failure = { step = "shortcuts_pause", mode = mode }
			helpers.assert_true(script_control.resume_all())
			ctx.fire_deferred()
			ctx.resume_callbacks[1](true, "native-resumed")
			helpers.assert_true(script_control.is_pause_transition_pending(),
				"native re-pause callback must still own the transition")
			helpers.assert_eq(ctx.calls.karabiner_pause, 2)

			ctx.pause_callbacks[2](true, "native-repaused")
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.is_pause_transition_pending(),
				"local inverse debt must outlive the now-terminal native transaction")
			helpers.assert_eq(script_control.pause_all(), false)
			helpers.assert_eq(ctx.calls.karabiner_pause, 2,
				"same-state local recovery may not publish a redundant native pause")

			ctx.pause_failure = nil
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			ctx.resume_failure = nil
			helpers.assert_true(script_control.resume_all())
			ctx.fire_deferred()
			ctx.resume_callbacks[2](true, "retry-resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("tracks a late pause-owner registration whose inverse also refuses", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			local script_control = load_context({ no_integration = true })
			helpers.assert_true(script_control.pause_all())
			local pause_mode = mode
			local resume_mode = mode
			local pause_calls = 0
			local resume_calls = 0
			local function result_for(current, label)
				if current == "throw" then error(label .. " exploded") end
				if current == "false" then return false end
				if current == "nil" then return nil end
				return true
			end
			local owner = {
				pause = function()
					pause_calls = pause_calls + 1
					return result_for(pause_mode, "late owner pause")
				end,
				resume = function()
					resume_calls = resume_calls + 1
					return result_for(resume_mode, "late owner resume")
				end,
			}

			helpers.assert_true(script_control.register_pause_owner("llm_activation", owner),
				"failed registration rollback must remain globally owned")
			helpers.assert_eq(pause_calls, 1)
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_true(script_control.is_pause_transition_pending())
			helpers.assert_eq(script_control.pause_all(), false)
			helpers.assert_eq(pause_calls, 2)
			helpers.assert_eq(resume_calls, 1,
				"same-state debt retry may not activate the late owner")

			pause_mode = "true"
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(pause_calls, 3)
			helpers.assert_eq(script_control.is_pause_transition_pending(), false)
			resume_mode = "true"
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(resume_calls, 2)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_true(script_control.stop())
		end
	end)

	helpers.it("rejects a PAUSE snapshot when a callback registers a new owner", function()
		local script_control, ctx = load_context({ no_integration = true })
		local active = true
		local pause_calls = 0
		local resume_calls = 0
		local owner = {
			pause = function()
				pause_calls = pause_calls + 1
				active = false
				return true
			end,
			resume = function()
				resume_calls = resume_calls + 1
				active = true
				return true
			end,
		}
		ctx.hooks.keymap_pause = function()
			ctx.hooks.keymap_pause = nil
			helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
		end

		helpers.assert_true(script_control.pause_all(),
			"the public request reports accepted input-drain ownership")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1,
			"the synchronously refused local commit must still be reported")
		helpers.assert_eq(pause_calls, 0,
			"registration while still ACTIVE must not pretend the new owner was paused")
		helpers.assert_eq(resume_calls, 0)
		helpers.assert_eq(active, true)
		helpers.assert_eq(ctx.calls.keymap_pause, 1)
		helpers.assert_eq(ctx.calls.keymap_resume, 1,
			"the stale PAUSE snapshot must roll its exact applied mutation back")

		helpers.assert_true(script_control.pause_all(),
			"the next PAUSE must inventory and quiesce the retained owner")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(pause_calls, 1)
		helpers.assert_eq(active, false)
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(resume_calls, 1)
		helpers.assert_eq(active, true)
		helpers.assert_true(script_control.stop())
	end)

	helpers.it("rejects a RESUME snapshot when a callback registers a paused owner", function()
		local script_control, ctx = load_context({ no_integration = true })
		helpers.assert_true(script_control.pause_all())
		local active = true
		local pause_calls = 0
		local resume_calls = 0
		local owner = {
			pause = function()
				pause_calls = pause_calls + 1
				active = false
				return true
			end,
			resume = function()
				resume_calls = resume_calls + 1
				active = true
				return true
			end,
		}
		ctx.hooks.keymap_resume = function()
			ctx.hooks.keymap_resume = nil
			helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
		end

		helpers.assert_eq(script_control.resume_all(), false,
			"a RESUME may not clear a ledger that grew inside an owner callback")
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(pause_calls, 1,
			"registration under PAUSED must quiesce the new owner immediately")
		helpers.assert_eq(resume_calls, 0,
			"the omitted owner may not be activated by the stale snapshot")
		helpers.assert_eq(active, false)
		helpers.assert_eq(ctx.calls.keymap_resume, 1)
		helpers.assert_eq(ctx.calls.keymap_pause, 2,
			"the already applied resume step must be rolled back exactly")

		helpers.assert_true(script_control.resume_all(),
			"the next RESUME must include the newly appended owner")
		helpers.assert_eq(resume_calls, 1)
		helpers.assert_eq(active, true)
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_true(script_control.stop())
	end)

	helpers.it("retains every resumed owner when admission and exact re-pause refuse", function()
		for _, release_mode in ipairs({ "false", "throw" }) do
			for _, pause_mode in ipairs({ "false", "nil", "throw" }) do
				local options = release_mode == "false"
					and { admission_release_failures = 1 }
					or { admission_release_throws = 1 }
				local script_control, ctx = load_context(options)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")
				local exact_fence = ctx.admission_fence

				ctx.pause_failure = { step = "shortcuts_pause", mode = pause_mode }
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[1](true, "native-resumed")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"native rollback and local re-pause debt must remain observable")
				helpers.assert_true(ctx.admission_fence == exact_fence)
				helpers.assert_eq(ctx.calls.shortcuts_pause, 2,
					"fallback must target the same owner that committed the original PAUSE")
				helpers.assert_eq(ctx.calls.shortcuts_resume, 1,
					"re-pause debt may not reacquire an activation successor")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2)

				ctx.pause_callbacks[2](true, "native-repaused")
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"terminal native re-pause may not consume unresolved local ownership")
				helpers.assert_eq(script_control.pause_all(), false,
					"same-state PAUSE must retry the retained owner without a successor")
				helpers.assert_eq(ctx.calls.shortcuts_pause, 3)
				helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"local debt recovery must not publish a redundant native request")

				ctx.pause_failure = nil
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(ctx.calls.shortcuts_pause, 4)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_nil(ctx.admission_fence)
				helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
				helpers.assert_true(ctx.admission_release_tokens[2] == exact_fence)
				helpers.assert_true(script_control.stop())
			end
		end
	end)

	helpers.it("does not replay one-way PAUSE cleanup after admission release refusal", function()
		for _, owner in ipairs({
			{ step = "keymap_reset", label = "prediction reset" },
			{ step = "tooltip_hide", label = "tooltip dismissal" },
		}) do
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				local script_control, ctx = load_context({ admission_release_failures = 1 })
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")
				helpers.assert_eq(ctx.calls[owner.step], 1,
					"positive control must commit the original " .. owner.label)

				ctx.pause_failure = { step = owner.step, mode = mode }
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[1](true, "native-resumed")
				helpers.assert_eq(ctx.calls[owner.step], 1,
					owner.label .. " was never resumed and must not be acquired again")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"native re-pause must remain owned until its callback settles")

				ctx.pause_callbacks[2](true, "native-repaused")
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_eq(ctx.calls[owner.step], 1,
					"terminal native compensation may not replay one-way work")
				ctx.pause_failure = nil
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(ctx.calls[owner.step], 1)
				helpers.assert_true(script_control.stop())
			end
		end
	end)

	helpers.it("keeps optional keylogger resync failures outside the activation transaction", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local script_control, ctx = load_context({
				resume_failure = { step = "keylogger_resync", mode = mode },
			})
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")

			helpers.assert_eq(ctx.calls.keylogger_resync, 1,
				"resume must still attempt the optional context refresh")
			helpers.assert_eq(script_control.is_paused(), false,
				"metrics OFF/uninitialized keylogger must not block an otherwise complete resume")
			helpers.assert_eq(ctx.calls.karabiner_pause, 1,
				"a non-activating optional failure must not roll native remapping back")
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
			helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			helpers.assert_true(has_warning_containing(ctx, "keylogger.resync_context"),
				"the optional failure must remain visible in the file logger")
			script_control.stop()
		end
	end)

	helpers.it("serializes a rapid pause then resume without overlapping native input", function()
		local script_control, ctx = load_context()
		script_control.pause_all()
		script_control.resume_all()
		ctx.fire_deferred()

		helpers.assert_eq(ctx.calls.karabiner_pause, 1)
		helpers.assert_eq(ctx.calls.karabiner_resume, nil,
			"the reversal must wait for PAUSED instead of overlapping controller input")
		ctx.pause_callback(true, "paused")
		helpers.assert_eq(script_control.is_paused(), true)

		ctx.fire_deferred()
		helpers.assert_eq(ctx.calls.karabiner_resume, 1)
		ctx.resume_callback(true, "resumed")
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.keymap_pause, 1)
		helpers.assert_eq(ctx.calls.keymap_resume, 1)
		helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
		script_control.stop()
	end)
end)
