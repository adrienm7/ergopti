--- tests/unit/modules/shortcuts/test_pause_owner_inventory.lua

--- Behavioral regression for HS-012's transactional pause-owner inventory.
--- The matrix drives every registered owner through false/nil/throw settlement,
--- then exercises the real facade, gesture search, startup, and model-switch
--- continuations so friendly no-op doubles cannot make the suite vacuous.

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

helpers.describe("HS-012 pause-owner class-wide settlement matrix", function()
	helpers.it("reports synthetic drain and native rollback from the exact transition owner", function()
		local pending_drain = nil
		local script_control = load_inventory_context({
			when_idle = function(callback)
				pending_drain = callback
				return true
			end,
		})
		helpers.assert_eq(script_control.is_pause_transition_pending(), false)
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"synthetic-input drain must own the unpublished pause boundary")
		helpers.assert_not_nil(pending_drain)
		pending_drain()
		helpers.assert_eq(script_control.is_pause_transition_pending(), false)
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(script_control.resume_all())
		script_control.stop()

		local native_callbacks = { pause = {}, resume = {} }
		local karabiner = {
			get_enabled = function() return true end,
			pause = function(callback)
				native_callbacks.pause[#native_callbacks.pause + 1] = callback
				return true
			end,
			resume = function(callback)
				native_callbacks.resume[#native_callbacks.resume + 1] = callback
				return true
			end,
		}
		local native_control, ctx = load_inventory_context({ karabiner = karabiner })
		helpers.assert_true(native_control.pause_all())
		helpers.assert_true(native_control.is_pause_transition_pending(),
			"the scheduled native candidate must keep the transition owned")
		local pause_timer = _G.hs.timer.__timers[#_G.hs.timer.__timers]
		pause_timer:fire()
		helpers.assert_true(native_control.is_pause_transition_pending())
		helpers.assert_not_nil(native_callbacks.pause[1])
		native_callbacks.pause[1](true)
		helpers.assert_true(native_control.is_paused())
		helpers.assert_eq(native_control.is_pause_transition_pending(), false)

		ctx.fail_owner = "remote_warmup"
		ctx.fail_direction = "resume"
		ctx.fail_mode = "false"
		ctx.failures_left = 1
		helpers.assert_true(native_control.resume_all())
		local resume_timer = _G.hs.timer.__timers[#_G.hs.timer.__timers]
		resume_timer:fire()
		helpers.assert_not_nil(native_callbacks.resume[1])
		native_callbacks.resume[1](true)
		helpers.assert_true(native_control.is_pause_transition_pending(),
			"native re-pause rollback must retain the same transaction owner")
		helpers.assert_not_nil(native_callbacks.pause[2])
		native_callbacks.pause[2](true)
		helpers.assert_true(native_control.is_paused())
		helpers.assert_eq(native_control.is_pause_transition_pending(), false)
		native_control.stop()
	end)

	helpers.it("reports an admission fence retained after a failed pause rollback", function()
		local release_mode = "false"
		local script_control = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			release_admission_fence = function(token, ctx)
				if release_mode ~= "true" then return false end
				token.active = false
				ctx.fence = nil
				return true
			end,
		})
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"a retained admission capability is exact unpublished transition debt")
		helpers.assert_true(script_control.pause_all(),
			"the next pause must reuse and commit the retained admission fence")
		helpers.assert_true(script_control.is_paused())
		helpers.assert_eq(script_control.is_pause_transition_pending(), false,
			"the same fence is stable ownership, not debt, after PAUSED commits")
		release_mode = "true"
		helpers.assert_true(script_control.resume_all())
		script_control.stop()
	end)

	helpers.it("exports the complete fixed owner inventory", function()
		local script_control, _ = load_inventory_context()
		helpers.assert_true(helpers.deep_equal(script_control.PAUSE_OWNER_IDS, OWNER_IDS),
			"the public inventory must enumerate every producer covered by pause")
		script_control.stop()
	end)

	helpers.it("selects the no-deferral prediction boundary for global pause", function()
		local generic_calls, pause_calls = 0, 0
		local script_control = load_inventory_context({
			keymap = {
				pause_processing = function() return true end,
				resume_processing = function() return true end,
				reset_predictions = function()
					generic_calls = generic_calls + 1
					return true
				end,
				reset_predictions_for_pause = function()
					pause_calls = pause_calls + 1
					return true
				end,
			},
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_eq(pause_calls, 1)
		helpers.assert_eq(generic_calls, 0,
			"pause may not arm ordinary dismissal telemetry")
		helpers.assert_true(script_control.resume_all())
		script_control.stop()
	end)

	for _, owner in ipairs(OWNER_IDS) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(owner .. " rejects " .. mode .. " settlement before PAUSED", function()
				local script_control, ctx = load_inventory_context({
					fail_owner = owner,
					fail_mode = mode,
				})
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 1,
						"positive-control callback must be live before pause")
				end

				script_control.pause_all()
				helpers.assert_eq(script_control.is_paused(), false,
					mode .. " from " .. owner .. " must not publish PAUSED")
				helpers.assert_true(helpers.deep_equal(ctx.listeners, {}))
				ctx.fire_every_late_callback()
				local post_failure_counts = {}
				for _, candidate in ipairs(OWNER_IDS) do
					local expected = ctx.active[candidate] == true and 2 or 1
					helpers.assert_eq(ctx.late_effects[candidate], expected,
						"failed pause must either restore or keep the callback fenced deterministically")
					post_failure_counts[candidate] = expected
				end

				helpers.assert_true(script_control.pause_all(),
					"the exact owner must remain retryable after " .. mode)
				helpers.assert_true(script_control.is_paused())
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], post_failure_counts[candidate],
						"no owner callback may publish while PAUSED")
				end
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true, false }))
				script_control.stop()
			end)
		end
	end

	for _, owner in ipairs(REVERSIBLE_OWNER_IDS) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(owner .. " rejects " .. mode .. " settlement before RESUMED", function()
				local script_control, ctx = load_inventory_context({
					fail_owner = owner,
					fail_mode = mode,
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.is_paused())
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 0,
						"positive paused control must fence every owner")
				end

				script_control.resume_all()
				helpers.assert_true(script_control.is_paused(),
					mode .. " from " .. owner .. " must not publish RESUMED")
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true }))
				ctx.fire_every_late_callback()
				for _, candidate in ipairs(OWNER_IDS) do
					helpers.assert_eq(ctx.late_effects[candidate], 0,
						"failed resume rollback must re-fence every mutated owner")
				end

				helpers.assert_true(script_control.resume_all(),
					"the exact activation owner must remain retryable after " .. mode)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(helpers.deep_equal(ctx.listeners, { true, false }))
				script_control.stop()
			end)
		end
	end

	helpers.it("retains the real gesture fence when resume rollback cleanup refuses", function()
		local cleanup_calls = 0
		local function permissive(overrides)
			return setmetatable(overrides, {
				__index = function() return function() return true end end,
			})
		end
		package.loaded["modules.gestures.engine"] = permissive({
			unblock_scroll = function() return true end,
		})
		package.loaded["modules.gestures.actions"] = permissive({
			force_cleanup = function()
				cleanup_calls = cleanup_calls + 1
				return cleanup_calls ~= 2
			end,
		})
		package.loaded["modules.gestures"] = nil
		local real_gestures = helpers.load_with_stubs("modules.gestures")
		local script_control = load_inventory_context({
			gestures = real_gestures,
			fail_owner = "remote_warmup",
			fail_mode = "false",
			fail_direction = "resume",
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(real_gestures.is_suspended())

		helpers.assert_eq(script_control.resume_all(), false)
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(real_gestures.is_suspended(),
			"a native cleanup refusal may not reopen gestures under PAUSED")
		helpers.assert_eq(cleanup_calls, 2,
			"positive control proves the rollback crossed the real cleanup boundary")

		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(real_gestures.is_suspended(), false)
		script_control.stop()
		package.loaded["modules.gestures"] = nil
		package.loaded["modules.gestures.engine"] = nil
		package.loaded["modules.gestures.actions"] = nil
	end)

	for _, owner in ipairs(OWNER_IDS) do
		helpers.it("does not resurrect inactive owner " .. owner, function()
			local script_control, ctx = load_inventory_context({ inactive_owner = owner })
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(ctx.active[owner], false,
				"resume may only restore an owner that was active before pause")
			if owner == "wpm_menubar" or owner == "wpm_widget"
				or owner == "shortcut_bindings" then
				helpers.assert_eq(ctx.calls[owner].resume, 0,
					"snapshot-gated owner must not even receive a resume call")
			end
			script_control.stop()
		end)
	end

	helpers.it("carries a refused inverse across snapshot-gated pause retry", function()
		local script_control, ctx = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			rollback_fail_owner = "shortcut_bindings",
			rollback_fail_mode = "false",
		})
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_true(script_control.is_pause_transition_pending(),
			"a refused inverse must keep the exact transition debt observable")
		helpers.assert_eq(ctx.active.shortcut_bindings, false,
			"the refused inverse must leave the snapshot-gated owner visibly inactive")
		helpers.assert_true(script_control.pause_all(),
			"the retained inverse debt must rejoin the next pause inventory")
		helpers.assert_eq(script_control.is_pause_transition_pending(), false,
			"the debt query must clear only after its exact owner settles")
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(ctx.active.shortcut_bindings, true,
			"the final committed resume must restore the original active intent")
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 2,
			"retry must quiesce the exact retained owner even when its snapshot is false")
		helpers.assert_eq(ctx.calls.shortcut_bindings.resume, 2,
			"one refused rollback plus one final restore must both be observable")
		script_control.stop()
	end)

	helpers.it("preserves an unvisited rollback debt across three pause attempts", function()
		local script_control, ctx = load_inventory_context({
			fail_owner = "remote_warmup",
			fail_mode = "false",
			rollback_fail_owner = "shortcut_bindings",
			rollback_fail_mode = "false",
		})
		script_control.pause_all()
		helpers.assert_eq(ctx.active.shortcut_bindings, false)

		ctx.fail_owner = "keymap_processing"
		ctx.fail_mode = "false"
		ctx.fail_direction = "pause"
		ctx.failures_left = 1
		script_control.pause_all()
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 1,
			"the earlier owner failure must occur before the retained shortcut debt")

		ctx.failures_left = 0
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(ctx.active.shortcut_bindings, true,
			"an unvisited debt may only be consumed after its own exact settlement")
		helpers.assert_eq(ctx.calls.shortcut_bindings.pause, 2)
		helpers.assert_eq(ctx.calls.shortcut_bindings.resume, 2)
		script_control.stop()
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates late owner registration after " .. mode, function()
			local script_control, ctx = load_inventory_context({
				skip_dynamic_owner = "llm_startup",
				inactive_owner = "llm_startup",
			})
			helpers.assert_true(script_control.pause_all())
			local pause_calls = 0
			local resume_calls = 0
			local active = true
			local registered = script_control.register_pause_owner("llm_startup", {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					error("late pause exploded")
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			})
			helpers.assert_eq(registered, false)
			helpers.assert_eq(active, true,
				"failed late registration must run its inverse after mutation")
			helpers.assert_eq(pause_calls, 1)
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(resume_calls, 1,
				"a settled registration rollback must not leak into the resume ledger")
			script_control.stop()
		end)
	end

	helpers.it("retains late-registration inverse debt until a later resume", function()
		local script_control, _ = load_inventory_context({
			skip_dynamic_owner = "llm_startup",
			inactive_owner = "llm_startup",
		})
		helpers.assert_true(script_control.pause_all())
		local active = true
		local pause_calls = 0
		local resume_calls = 0
		local pause_settles = false
		helpers.assert_true(script_control.register_pause_owner("llm_startup", {
			pause = function()
				pause_calls = pause_calls + 1
				active = false
				return pause_settles
			end,
			resume = function()
				resume_calls = resume_calls + 1
				if resume_calls == 1 then return false end
				active = true
				return true
			end,
		}))
		helpers.assert_eq(active, false)
		helpers.assert_true(script_control.is_pause_transition_pending())
		helpers.assert_eq(script_control.resume_all(), false,
			"resume must first re-pause the exact owner whose registration inverse refused")
		helpers.assert_eq(pause_calls, 2)
		helpers.assert_eq(resume_calls, 1,
			"no activation successor may run over retained re-pause debt")

		pause_settles = true
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(active, true)
		helpers.assert_eq(pause_calls, 3,
			"the settled retry must target the same retained pause owner")
		helpers.assert_eq(resume_calls, 2,
			"the exact late owner must remain in the resume ledger after refusal")
		script_control.stop()
	end)
end)

local function load_real_wpm_surface(module_name)
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	local cancel_mode = "true"
	local handles = {}
	local cancellations = {}
	package.loaded["adapters.timer_scheduler"] = {
		every = function(_, callback)
			local handle = { callback = callback }
			handles[#handles + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			cancellations[#cancellations + 1] = handle
			if cancel_mode == "false" then return false end
			if cancel_mode == "nil" then return nil end
			if cancel_mode == "throw" then error("WPM timer cancellation exploded") end
			return true
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm = 0 } end,
	}
	package.loaded["ui.wpm.shared"] = {
		get_active_source = function() return "none" end,
		get_source_color = function() return nil end,
		format_mpm_label = function(value) return tostring(value) end,
	}
	package.loaded["infra.paths"] = { shared = function() return nil end }
	package.loaded["adapters.graphics_renderer"] = {}
	package.loaded["ui.tooltip"] = { is_visible = function() return false end }
	reset_module(module_name)
	local surface = require(module_name)
	return surface, {
		handles = handles,
		cancellations = cancellations,
		set_cancel_mode = function(value) cancel_mode = value end,
	}
end

helpers.describe("HS-012 real WPM pause-restoration debt", function()
	for _, module_name in ipairs({
		"ui.wpm.wpm_menubar",
		"ui.wpm.wpm_widget",
	}) do
		helpers.it(module_name .. " survives stop-refusal, rollback-refusal, retry, resume", function()
			local surface, ctx = load_real_wpm_surface(module_name)
			helpers.assert_true(surface.start(false))
			helpers.assert_eq(#ctx.handles, 1,
				"positive control must own one real recurring WPM capability")

			ctx.set_cancel_mode("false")
			helpers.assert_eq(surface.stop(), false)
			helpers.assert_eq(surface.resume_after_pause(), false,
				"the simulated pause rollback must retain the exact timer debt")
			helpers.assert_true(surface.is_running(),
				"pre-pause running intent must survive while the runtime is stopped")

			ctx.set_cancel_mode("true")
			helpers.assert_true(surface.stop(),
				"a later pause retry must settle the original capability")
			helpers.assert_true(surface.is_running(),
				"settling cleanup must not erase the still-owed restore intent")
			helpers.assert_true(surface.resume_after_pause())
			helpers.assert_eq(#ctx.handles, 2,
				"the final resume must acquire one replacement runtime, exactly once")
			helpers.assert_true(surface.stop())
		end)
	end
end)

local function load_real_search_capture(stop_mode, click_mode, compose_gestures)
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.gestures%.actions") then
			package.loaded[name] = nil
		end
	end
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local selection_reads = 0
	hs_stub.pasteboard.readAllData = function()
		return { ["public.utf8-plain-text"] = "ORIGINAL" }
	end
	hs_stub.pasteboard.clearContents = function() return true end
	hs_stub.pasteboard.getContents = function()
		selection_reads = selection_reads + 1
		return "selected words"
	end
	hs_stub.pasteboard.writeAllData = function() return true end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = { sec = function() return 0.2 end }
	package.loaded["adapters.synthetic_input"] = setmetatable({
		emit_key_stroke = function() return true end,
		defer_after_callback = function() return false end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.actions_click"] = setmetatable({
		force_cleanup = function()
			if click_mode == "false" then return false end
			if click_mode == "nil" then return nil end
			if click_mode == "throw" then error("click cleanup exploded") end
			return true
		end,
	}, { __index = function() return function() return true end end })
	package.loaded["modules.gestures.sticky_modifiers"] = {
		toggle = function() return true end,
		clear = function() return true end,
	}

	local actions = require("modules.gestures.actions")
	local gestures = nil
	local gesture_engine = nil
	if compose_gestures then
		local function permissive(overrides)
			return setmetatable(overrides or {}, {
				__index = function() return function() return true end end,
			})
		end
		gesture_engine = permissive({
			init = function() return true end,
			unblock_scroll = function() return true end,
		})
		package.loaded["modules.gestures.engine"] = gesture_engine
		package.loaded["modules.gestures.conflicts"] = permissive()
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return false end,
		}
		package.loaded["adapters.timer_scheduler"] = permissive({
			cancel = function() return true end,
		})
		package.loaded["modules.gestures"] = nil
		gestures = require("modules.gestures")
	else
		actions.init({ action_params = {} })
	end
	helpers.assert_true(actions.set_action_parameter(
		"tap_3", "search_web", "https://example.test/?q=%s"))
	helpers.assert_true(actions.execute_single("search_web", "tap_3"))
	local capture_timer = hs_stub.timer.__timers[#hs_stub.timer.__timers]
	helpers.assert_not_nil(capture_timer,
		"the real search action must own a positive-control capture timer")
	local native_stop = capture_timer.stop
	local current_stop_mode = stop_mode
	capture_timer.stop = function(self)
		if current_stop_mode == "false" then return false end
		if current_stop_mode == "nil" then return nil end
		if current_stop_mode == "throw" then error("timer stop exploded") end
		return native_stop(self)
	end
	return actions, hs_stub, capture_timer, function() return selection_reads end,
		function(mode) current_stop_mode = mode end, gestures, gesture_engine
end

helpers.describe("HS-012 real gesture-search ownership", function()
	helpers.it("opens a URL on the authorized positive-control timer", function()
		local _, hs_stub, capture_timer, selection_reads = load_real_search_capture()
		capture_timer:fire()
		helpers.assert_eq(selection_reads(), 1)
		helpers.assert_eq(#hs_stub.urlevent.__opened, 1,
			"the positive control proves the production callback can publish a URL")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences a live search timer when stop returns " .. mode, function()
			local actions, hs_stub, capture_timer, selection_reads =
				load_real_search_capture(mode)
			helpers.assert_eq(actions.force_cleanup(), false,
				"cleanup refusal must propagate to the gesture lifecycle")
			-- Deliver the native callback despite the refused stop. The exact slot
			-- remains retained, but authority was synchronously revoked first.
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0,
				"a refused search timer may never open a browser after cleanup")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates a " .. mode .. " click cleanup without leaking search", function()
			local actions, hs_stub, capture_timer, selection_reads =
				load_real_search_capture(nil, mode)
			helpers.assert_eq(actions.force_cleanup(), false,
				"the aggregate cleanup contract must require exact click settlement")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
		end)
	end
end)

helpers.describe("HS-012 real gesture-search pause composition", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("settles a " .. mode .. " search timer through real Gestures and ScriptControl", function()
			local actions, hs_stub, capture_timer, selection_reads, set_stop_mode,
				real_gestures, gesture_engine = load_real_search_capture(mode, nil, true)
			local timer_count = #hs_stub.timer.__timers
			local suspended_during_stop = false
			local stop_calls = 0
			local stop_identities = {}
			local adverse_stop = capture_timer.stop
			capture_timer.stop = function(self)
				stop_calls = stop_calls + 1
				stop_identities[#stop_identities + 1] = self
				suspended_during_stop = suspended_during_stop or real_gestures.is_suspended()
				return adverse_stop(self)
			end

			local script_control = load_inventory_context({
				gestures = real_gestures,
				gesture_actions = actions,
				gesture_engine = gesture_engine,
			})
			helpers.assert_true(script_control.pause_all(),
				"the public request reports drain acceptance, not local commit")
			helpers.assert_eq(script_control.is_paused(), false,
				"a refused native search cleanup must not publish PAUSED")
			helpers.assert_true(suspended_during_stop,
				"Gestures must close its logical delivery fence before fallible timer cleanup")
			helpers.assert_eq(stop_calls, 2,
				"the faulting pause step and its inverse must retry the same search debt")
			helpers.assert_eq(stop_identities[1], capture_timer)
			helpers.assert_eq(stop_identities[2], capture_timer,
				"pause rollback must not replace the refused native timer")

			set_stop_mode("true")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused(),
				"retry must settle the retained timer before committing PAUSED")
			helpers.assert_true(real_gestures.is_suspended())
			helpers.assert_eq(stop_calls, 3)
			helpers.assert_eq(stop_identities[3], capture_timer,
				"the retry must settle the same retained native timer, not a successor")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			local timer_count_after_pause = #hs_stub.timer.__timers

			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(real_gestures.is_suspended(), false)
			helpers.assert_true(timer_count_after_pause >= timer_count)
			helpers.assert_eq(#hs_stub.timer.__timers, timer_count_after_pause,
				"RESUME may reopen gesture delivery but must not resurrect a stale search")
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			script_control.stop()
			package.loaded["modules.gestures"] = nil
		end)

		helpers.it("accepts the exact late terminal after a " .. mode .. " search stop", function()
			local actions, hs_stub, capture_timer, selection_reads, set_stop_mode,
				real_gestures, gesture_engine = load_real_search_capture(mode, nil, true)
			local stop_calls = 0
			local stop_identities = {}
			local adverse_stop = capture_timer.stop
			capture_timer.stop = function(self)
				stop_calls = stop_calls + 1
				stop_identities[#stop_identities + 1] = self
				return adverse_stop(self)
			end

			local script_control = load_inventory_context({
				gestures = real_gestures,
				gesture_actions = actions,
				gesture_engine = gesture_engine,
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(stop_calls, 2,
				"the faulting pause step and its inverse must retain the same timer")
			helpers.assert_eq(stop_identities[1], capture_timer)
			helpers.assert_eq(stop_identities[2], capture_timer)

			capture_timer:fire()
			helpers.assert_eq(capture_timer.running, false,
				"one-shot delivery is exact terminal proof for the refused timer")
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0,
				"the late terminal remains behind the gesture delivery fence")

			set_stop_mode("true")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_eq(stop_calls, 2,
				"retry must not cancel a one-shot capability that already terminated")
			local timer_count_after_pause = #hs_stub.timer.__timers

			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(real_gestures.is_suspended(), false)
			helpers.assert_eq(#hs_stub.timer.__timers, timer_count_after_pause)
			capture_timer.fn()
			helpers.assert_eq(selection_reads(), 0)
			helpers.assert_eq(#hs_stub.urlevent.__opened, 0)
			script_control.stop()
			package.loaded["modules.gestures"] = nil
		end)
	end
end)

local function load_real_sticky_pause_owner()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.gestures%.actions")
			or name == "modules.gestures.sticky_modifiers"
			or name == "modules.gestures"
			or name == "adapters.modifier_injector"
			or name == "adapters.timer_scheduler") then
			package.loaded[name] = nil
		end
	end
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local native_timers = {}
	hs_stub.timer.new = function(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			stop_mode = "true",
		}
		function timer:start()
			self.start_calls = self.start_calls + 1
			self.running_state = true
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("sticky timer stop exploded") end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:deliver() callback() end
		native_timers[#native_timers + 1] = timer
		return timer
	end

	local deferred = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.event_provenance"] = {
		STATUS_UNREADABLE = "unreadable",
		classify_with_fence = function() return nil, "foreign", nil end,
	}
	package.loaded["adapters.synthetic_input"] = setmetatable({
		defer_after_callback = function(_label, callback)
			deferred[#deferred + 1] = callback
			return true
		end,
	}, { __index = function() return function() return true end end })

	local TimerScheduler = require("adapters.timer_scheduler")
	local Injector = require("adapters.modifier_injector")
	local Sticky = require("modules.gestures.sticky_modifiers")

	local function permissive(overrides)
		return setmetatable(overrides or {}, {
			__index = function() return function() return true end end,
		})
	end
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.paths"] = { shared = function(path) return "missing/" .. path end }
	package.loaded["infra.timings"] = { sec = function() return 0.2 end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = permissive({
		escape_gsub_replacement = function(value) return value end,
	})
	package.loaded["adapters.file_system"] = permissive({ read = function() return nil end })
	package.loaded["adapters.key_state"] = permissive({
		is_right_altgr_held = function() return false end,
		describe_held_modifiers = function() return "(none)" end,
	})
	package.loaded["adapters.shell_runner"] = permissive()
	package.loaded["infra.termination_coordinator"] = permissive()
	local function scoped_child(pause_name, resume_name, query_name, pending_name)
		local paused = {}
		return {
			[pause_name] = function(parent) paused[parent] = true; return true end,
			[resume_name] = function(parent) paused[parent] = false; return true end,
			[query_name] = function(parent) return paused[parent] == true end,
			[pending_name] = function() return false end,
		}
	end
	package.loaded["modules.shortcuts.actions.text"] = scoped_child(
		"pause_text_actions", "resume_text_actions",
		"is_text_actions_paused", "has_pending_text_action")
	package.loaded["modules.shortcuts.actions.system_mouse"] = scoped_child(
		"pause_mouse_actions", "resume_mouse_actions",
		"is_mouse_actions_paused", "has_pending_mouse_action")
	package.loaded["modules.shortcuts.actions.screenshot_save"] = scoped_child(
		"pause_screenshot_actions", "resume_screenshot_actions",
		"has_screenshot_pause_claim", "has_pending_screenshot_action")
	package.loaded["modules.gestures.actions_click"] = permissive({
		force_cleanup = function() return true end,
	})
	package.loaded["modules.gestures.sticky_modifiers"] = Sticky
	reset_module("modules.gestures.actions")
	local actions = require("modules.gestures.actions")

	local gesture_engine = permissive({
		init = function() return true end,
		unblock_scroll = function() return true end,
	})
	package.loaded["modules.gestures.engine"] = gesture_engine
	package.loaded["modules.gestures.actions"] = actions
	package.loaded["modules.gestures.conflicts"] = permissive()
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
	package.loaded["adapters.timer_scheduler"] = TimerScheduler
	reset_module("modules.gestures")
	local gestures = require("modules.gestures")

	local function flush_deferred()
		local snapshot = deferred
		deferred = {}
		for _, callback in ipairs(snapshot) do callback() end
	end

	return {
		hs = hs_stub,
		timers = native_timers,
		injector = Injector,
		sticky = Sticky,
		actions = actions,
		gestures = gestures,
		gesture_engine = gesture_engine,
		flush_deferred = flush_deferred,
		deferred_count = function() return #deferred end,
	}
end

local function sticky_physical_event()
	local observed = { set_calls = 0, flags = {} }
	local event = {
		getFlags = function() return {} end,
		setFlags = function(_, flags)
			observed.set_calls = observed.set_calls + 1
			observed.flags = flags
		end,
	}
	return event, observed
end

helpers.describe("HS-012 real sticky-modifier pause ownership", function()
	for _, owner_kind in ipairs({ "timer", "injector" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("joins the exact " .. owner_kind .. " after " .. mode .. " cleanup", function()
				local fixture = load_real_sticky_pause_owner()

				-- Positive control: the real adapter can mutate a physical event while
				-- ACTIVE, and its deferred policy handoff consumes the first arm.
				helpers.assert_eq(fixture.sticky.toggle({ "cmd" }, 1), true)
				local positive_tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
				local positive_event, positive_observed = sticky_physical_event()
				positive_tap.fn(positive_event)
				fixture.flush_deferred()
				helpers.assert_eq(positive_observed.set_calls, 1)
				helpers.assert_eq(positive_observed.flags.cmd, true)
				helpers.assert_eq(next(fixture.sticky.armed()), nil)

				helpers.assert_eq(fixture.sticky.toggle({ "shift" }, 1), true)
				local target_timer = fixture.timers[#fixture.timers]
				local target_tap = fixture.hs.eventtap.__taps[#fixture.hs.eventtap.__taps]
				helpers.assert_not_nil(target_timer)
				helpers.assert_not_nil(target_tap)
				helpers.assert_true(target_tap ~= positive_tap,
					"the adverse arm must own a distinct exact eventtap")

				local tap_stop_calls = 0
				local tap_stop_identities = {}
				local tap_stop_mode = owner_kind == "injector" and mode or "true"
				local native_tap_stop = target_tap.stop
				target_tap.stop = function(self)
					tap_stop_calls = tap_stop_calls + 1
					tap_stop_identities[tap_stop_calls] = self
					if tap_stop_mode == "false" then return false end
					if tap_stop_mode == "nil" then return nil end
					if tap_stop_mode == "throw" then error("sticky tap stop exploded") end
					return native_tap_stop(self)
				end
				target_timer.stop_mode = owner_kind == "timer" and mode or "true"

				local script_control = load_inventory_context({
					gestures = fixture.gestures,
					gesture_actions = fixture.actions,
					gesture_engine = fixture.gesture_engine,
				})
				local suspended_during_cleanup = false
				if owner_kind == "timer" then
					local native_stop = target_timer.stop
					target_timer.stop = function(self)
						suspended_during_cleanup = suspended_during_cleanup
							or fixture.gestures.is_suspended()
						return native_stop(self)
					end
				else
					local adverse_stop = target_tap.stop
					target_tap.stop = function(self)
						suspended_during_cleanup = suspended_during_cleanup
							or fixture.gestures.is_suspended()
						return adverse_stop(self)
					end
				end

				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(script_control.is_paused(), false,
					"refused Sticky cleanup must prevent PAUSED publication")
				helpers.assert_true(suspended_during_cleanup,
					"Gestures must publish its logical fence before Sticky cleanup")
				local retained_modifier = owner_kind == "injector" and "shift" or nil
				helpers.assert_eq(next(fixture.sticky.armed()), retained_modifier,
					"only refused injector cleanup retains the exact logical modifier debt")

				local old_event, old_observed = sticky_physical_event()
				local deferred_before_late = fixture.deferred_count()
				target_tap.fn(old_event)
				target_timer:deliver()
				fixture.flush_deferred()
				helpers.assert_eq(old_observed.set_calls, 0,
					"a retained native tap must be inert after its delivery fence closes")
				helpers.assert_eq(fixture.deferred_count(), 0)
				helpers.assert_eq(deferred_before_late, 0)
				helpers.assert_eq(next(fixture.sticky.armed()), retained_modifier,
					"late callbacks stay inert without erasing retryable injector identity")

				target_timer.stop_mode = "true"
				tap_stop_mode = "true"
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(next(fixture.sticky.armed()), nil,
					"the owning retry must clear the logical identity after native settlement")
				if owner_kind == "timer" then
					helpers.assert_true(target_timer.stop_calls >= 3,
						"retry and late delivery must keep targeting the same timer")
					for _, identity in ipairs(target_timer.stop_identities) do
						helpers.assert_true(identity == target_timer,
							"every retry must retain the exact timer capability")
					end
				else
					helpers.assert_eq(tap_stop_calls, 3,
						"pause, inverse, and retry must target the same retained eventtap")
					helpers.assert_true(tap_stop_identities[1] == target_tap,
						"first injector cleanup must target the exact eventtap")
					helpers.assert_true(tap_stop_identities[2] == target_tap,
						"pause inverse must retain the exact eventtap")
					helpers.assert_true(tap_stop_identities[3] == target_tap,
						"retry injector cleanup must settle the exact eventtap")
				end

				local timer_count = #fixture.timers
				local tap_count = #fixture.hs.eventtap.__taps
				target_tap.fn(old_event)
				target_timer:deliver()
				helpers.assert_eq(old_observed.set_calls, 0)
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(fixture.gestures.is_suspended(), false)
				helpers.assert_eq(#fixture.timers, timer_count,
					"RESUME must not resurrect a consumed Sticky timer")
				helpers.assert_eq(#fixture.hs.eventtap.__taps, tap_count,
					"RESUME must not resurrect a consumed modifier eventtap")
				target_tap.fn(old_event)
				target_timer:deliver()
				helpers.assert_eq(old_observed.set_calls, 0)
				script_control.stop()
			end)
		end
	end
end)

helpers.describe("HS-012 real shortcuts facade wiring", function()
	helpers.it("carries pause epoch and both runtime owners through the injected facade", function()
		local epoch = 41
		local transition_pending = true
		local registrations = {}
		local requirement_capabilities = {}
		local models_mgr = {
			create_requirement_owner = function(label)
				local capability = { label = label }
				requirement_capabilities[#requirement_capabilities + 1] = capability
				return capability
			end,
			pause_requirements = function(capability)
				return type(capability) == "table"
			end,
		}
		package.loaded["modules.shortcuts.bindings"] = {
			DEFAULT_CHATGPT_URL = "https://example.test",
			list_shortcuts = function() return {} end,
			enable = function() return true end,
			disable = function() return true end,
			is_enabled = function() return true end,
			set_wrap_pairs_getter = function() return true end,
			set_chatgpt_url = function() return true end,
			start = function() return true end,
			stop = function() return true end,
			is_started = function() return false end,
			rebind = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = {
			ACTIONS = {},
			ACTION_LABELS = {},
			PAUSE_OWNER_IDS = OWNER_IDS,
			start = function() return true end,
			stop = function() return true end,
			is_paused = function() return false end,
			is_pause_transition_pending = function() return transition_pending end,
			get_pause_epoch = function() return epoch end,
			register_pause_owner = function(name, owner)
				registrations[#registrations + 1] = { name = name, owner = owner }
				return true
			end,
			set_shortcut_action = function() return true end,
			set_on_pause_change = function() return true end,
			set_extras = function() return true end,
			toggle = function() return true end,
		}
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = setmetatable({
			start = function() return true end,
			stop = function() return true end,
		}, { __index = function() return function() return true end end })
		package.loaded["adapters.hotkey_registrar"] = {
			set_delivery_guard = function(guard)
				helpers.assert_true(guard())
				return true
			end,
		}
		package.loaded["infra.startup_transaction"] = {
			run = function() return true end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local shortcuts = helpers.load_with_stubs("modules.shortcuts")
		helpers.assert_true(shortcuts.is_pause_transition_pending(),
			"the real facade must expose the live ScriptControl transition owner")
		transition_pending = false
		helpers.assert_eq(shortcuts.is_pause_transition_pending(), false,
			"the facade must not snapshot transition state at module construction")
		helpers.assert_eq(shortcuts.get_pause_epoch(), 41,
			"the real facade must expose the exact ScriptControl epoch")
		epoch = 42
		helpers.assert_eq(shortcuts.get_pause_epoch(), 42,
			"the facade must not snapshot the epoch at module construction")

		-- Drive the real root menu controller far enough to cross its dependency
		-- injection boundary. A source scan for the field name passed while the
		-- facade itself forgot the proxy, which is the topology regression HS-012
		-- needs to make impossible.
		local injected_control = nil
		local injected_update_menu = nil
		local noop = function() end
		local state = {
			trigger_char = "*",
			hotstrings = {},
			terminator_states = {},
			script_control_shortcuts = {},
			keymap = true,
			gestures = true,
			shortcuts = true,
			llm_enabled = false,
			keylogger_enabled = false,
			script_control_enabled = true,
			personal_info = false,
			update_channel = "dev",
			update_check_interval_seconds = 3600,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["ui.hotstring_editor"] = { set_update_menu = noop }
		package.loaded["infra.text_utils"] = {
			escape_gsub_replacement = function(value) return value end,
			shell_quote = function(value) return value end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.ui_restore"] = {}
		package.loaded["infra.preferences"] = {
			build_initial_state = function() return state end,
			load = function() return {}, "present" end,
			merge_saved_data = noop,
			snapshot = function() return {} end,
			save = function() return true end,
			get_group_name = function() return "test" end,
		}
		package.loaded["ui.menu.preferences_transaction"] = {
			clone = function(value)
				local copy = {}
				for key, item in pairs(value) do copy[key] = item end
				return copy
			end,
			restore_table = function() return true end,
			bind = function() return function() return true end end,
		}
		package.loaded["ui.menu.global_actions_transaction"] = {
			create = function()
				return {
					disable_all = function() return true end,
					reset_defaults = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.recoverable_file_moves"] = {
			create = function() return {} end,
		}
		package.loaded["ui.menu.builder"] = {
			generate = function() return {} end,
			invalidate_cache = noop,
		}
		package.loaded["ui.menu.hotstring_counter"] = { invalidate_cache = noop }
		package.loaded["ui.menu.menu_paths"] = {
			is_initialized = function() return true end,
			get = function() return "/virtual/config.toml" end,
			get_config_dir = function() return "/virtual" end,
			open_editor = noop,
		}
		package.loaded["infra.factory_reset_journal"] = {
			path_for = function(config_path)
				if type(config_path) ~= "string" or config_path == "" then return nil end
				return config_path .. ".ergopti-reset-journal-v1.json"
			end,
			create = function(journal_path)
				if type(journal_path) ~= "string" or journal_path == "" then
					return nil, "journal path must be a non-empty string"
				end
				return {
					prepare = function() return true end,
					mark_commit = function() return true end,
					mark_prepared = function() return true end,
					clear = function() return true end,
				}
			end,
		}
		package.loaded["ui.menu.menu_state"] = {
			sync_state_to_modules = function() return true end,
		}
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["ui.menu.menu_watchers"] = {
			start_config_watcher = function()
				return { stop = function() return true end }
			end,
			start_theme_watcher = function()
				return { stop = function() return true end }
			end,
		}
		package.loaded["modules.updater"] = {
			get_check_interval = function() return 3600 end,
			start_background_checks = noop,
		}
		package.loaded["adapters.tray_menu"] = {
			adopt = function() return true end,
			setMenu = function() return true end,
			destroy = noop,
		}
		package.loaded["chord"] = { format = function() return "ctrl+x" end }
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function() return {} end,
			setEnabled = function() return true end,
			unbind = function() return true end,
		}
		package.loaded["infra.termination_coordinator"] = {
			request_exit = function() return true end,
			request_reload = function() return true end,
		}
		for _, module_name in ipairs({
			"ui.menu.menu_gestures",
			"ui.menu.menu_shortcuts",
			"ui.menu.menu_keyboard_layout",
			"ui.menu.menu_hotstrings",
			"ui.menu.menu_metrics",
			"ui.menu.menu_remap",
			"ui.menu.menu_apps",
			"ui.menu.menu_about",
		}) do
			package.loaded[module_name] = {}
		end
		package.loaded["ui.menu.menu_llm"] = {
			create = function(deps)
				injected_control = deps.script_control
				injected_update_menu = deps.update_menu
				return {}
			end,
		}
		package.loaded["modules.llm"] = { set_backend = function() return true end }
		package.loaded["modules.keylogger"] = {}
		package.loaded["modules.shortcuts"] = shortcuts
		package.loaded["modules.dynamic_hotstrings"] = {}
		package.loaded["modules.gestures"] = { SINGLE_SLOTS = {}, DEFAULT_GESTURES = {} }
		package.loaded["infra.personal_shortcuts"] = { load = noop }
		package.loaded["ui.menu.init"] = nil
		local Menu = require("ui.menu.init")
		local menu = Menu.start("/virtual/", {}, {}, {}, {}, {}, nil, {})
		helpers.assert_not_nil(menu,
			"the real root menu must reach its LLM dependency-injection boundary")
		helpers.assert_true(injected_control == shortcuts,
			"ui.menu must inject the real shortcuts facade, not ScriptControl or a snapshot")
		helpers.assert_eq(injected_update_menu(), true,
			"the root adapter must acknowledge an exact menu publication")
		epoch = 43
		helpers.assert_eq(injected_control.get_pause_epoch(), 43,
			"the root-injected facade must expose the live ScriptControl epoch")
		transition_pending = true
		helpers.assert_true(injected_control.is_pause_transition_pending(),
			"the root-injected facade must expose the live transition owner")

		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = {},
			DEFAULT_STATE = { llm_num_predictions = 1 },
		}
		package.loaded["ui.menu.menu_llm.startup_controller"] = nil
		local StartupController = require("ui.menu.menu_llm.startup_controller")
		StartupController.new({
			state = {},
			keymap = {},
			models_mgr = models_mgr,
			guarded_check_requirements = function() return true end,
			save_prefs = function() return true end,
			update_menu = function() return true end,
			apply_llm_shortcut = function() return true end,
			apply_llm_profile_shortcut = function() return true end,
			activate_hotkey = function() return true end,
			mlx_deps_checker = {},
			deps = { script_control = shortcuts },
			get_startup_silence = function() return false end,
			set_startup_silence = function() return true end,
			get_trigger_hk = function() return nil end,
			get_profile_hks = function() return {} end,
		})

		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil
		local ModelSwitcher = require("ui.menu.menu_llm.model_switcher")
		ModelSwitcher.new({
			state = { llm_enabled = false },
			models_mgr = models_mgr,
			keymap = {},
			script_control = shortcuts,
			save_prefs = function() return true end,
			update_menu = function() return true end,
		})

		helpers.assert_eq(#requirement_capabilities, 2,
			"startup and model switching must each own a distinct manager capability")
		helpers.assert_true(requirement_capabilities[1] ~= requirement_capabilities[2])
		helpers.assert_eq(requirement_capabilities[1].label, "startup")
		helpers.assert_eq(requirement_capabilities[2].label, "model_switcher")
		helpers.assert_eq(#registrations, 2)
		helpers.assert_eq(registrations[1].name, "llm_startup")
		helpers.assert_eq(registrations[2].name, "llm_model_switcher")
		helpers.assert_eq(type(registrations[1].owner.pause), "function")
		helpers.assert_eq(type(registrations[2].owner.resume), "function")

	end)

	helpers.it("injects one registry identity into real menu startup and switch wiring", function()
		local noop = function() return true end
		local sentinel = {
			apply_preference = noop,
		}
		local facade = {}
		local switch_ctx = nil
		local startup_ctx = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["ui.menu.shortcut_utils"] = {}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_enabled = false,
				llm_backend = "ollama",
				llm_model_ollama = "",
				llm_model_mlx = "",
				llm_num_predictions = 1,
			},
			BUILTIN_PROFILES = {},
			get_backend = function() return "ollama" end,
			get_current_model = function() return "" end,
			set_backend = function() return true end,
			set_llm_model_mlx = function() return true end,
			set_llm_model_ollama = function() return true end,
		}
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function()
				return {
					get_presets = function() return {} end,
					get_actual_model_name = function(value) return value end,
					get_model_info = function() return {} end,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function() return { get_menu_item = function() return {} end } end,
		}
		package.loaded["ui.menu.menu_llm.settings_manager"] = {
			new = function() return {} end,
		}
		for _, name in ipairs({
			"ui.menu.menu_llm.temperature_panel",
			"ui.menu.menu_llm.streaming_panel",
			"ui.menu.menu_llm.trigger_panel",
			"ui.menu.menu_llm.api_panel",
			"ui.menu.menu_llm.models_selector",
		}) do
			package.loaded[name] = { build = function() return {} end }
		end
		package.loaded["ui.menu.menu_llm.api_panel"].build_model_picker = function() return {} end
		package.loaded["ui.menu.menu_llm.warmup_controller"] = {}
		package.loaded["ui.menu.menu_llm.backend_panel"] = {
			is_apple_silicon = function() return false end,
			build = function() return "backend", {} end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = {
			new = function(ctx)
				switch_ctx = ctx
				return {
					switch_model = noop,
					disable_model = noop,
					set_llm_profile = noop,
					settle_recovery_debts = noop,
					apply_recommended_prompt_profile = noop,
					get_display_model_name = function(value) return value end,
					get_model_power_level = function() return 1 end,
					guarded_check_requirements = noop,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.prediction_lock_registry"] = {
			new = function() return sentinel end,
		}
		package.loaded["modules.llm.api_mlx"] = { get_base_url = function() return "" end }
		package.loaded["ui.menu.menu_llm.startup_controller"] = {
			new = function(ctx) startup_ctx = ctx; return noop end,
		}
		package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
			new = function()
				return {
					bind_hotkey = noop,
					activate_hotkey = noop,
					apply_llm_shortcut = noop,
					apply_llm_profile_shortcut = noop,
					restore_shortcuts = noop,
				}
			end,
		}
		package.loaded["ui.menu.menu_llm.menu_layout"] = {
			row_ids = function() return {} end,
			row_disabled = function() return false end,
			has_health_dot = function() return false end,
		}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
			build = function() return {} end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = { check_and_install_deps = noop }
		package.loaded["modules.llm.ollama_deps_checker"] = { check_and_install_deps = noop }
		reset_module("ui.menu.menu_llm")
		local MenuLLM = require("ui.menu.menu_llm")
		local handler = MenuLLM.create({
			state = {
				llm_enabled = false,
				llm_backend = "ollama",
				llm_model = "",
				llm_profile_shortcuts = {},
			},
			keymap = {
				set_llm_model = function() return true end,
				set_llm_display_model_name = noop,
			},
			save_prefs = noop,
			update_menu = noop,
			active_tasks = {},
			script_control = facade,
		})
		helpers.assert_not_nil(handler)
		helpers.assert_true(switch_ctx.prediction_locks == sentinel)
		helpers.assert_true(startup_ctx.prediction_locks == sentinel,
			"both real factory injections must share the exact registry table")
		helpers.assert_true(switch_ctx.script_control == facade,
			"the menu must pass the exact ScriptControl facade into ModelSwitcher")
		helpers.assert_true(startup_ctx.deps.script_control == facade,
			"the menu must pass the exact ScriptControl facade into StartupController")
	end)
end)

local function load_real_keep_awake_owner()
	local arm_mode = "true"
	local cancel_mode = "true"
	local handles = {}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, callback)
			if arm_mode == "throw" then error("keep-awake timer arm exploded") end
			local handle = { timer = {}, callback = callback }
			handles[#handles + 1] = handle
			if arm_mode == "false" then return handle, false end
			if arm_mode == "nil" then return handle, nil end
			return handle, true
		end,
		cancel = function(handle)
			if cancel_mode == "throw" then error("keep-awake timer cancel exploded") end
			if cancel_mode == "false" then return false end
			if cancel_mode == "nil" then return nil end
			handle.timer = nil
			return true
		end,
	}
	package.loaded["modules.shortcuts.actions.system"] = nil
	local system = helpers.load_with_stubs("modules.shortcuts.actions.system")
	return {
		system = system,
		handles = handles,
		set_arm_mode = function(mode) arm_mode = mode end,
		set_cancel_mode = function(mode) cancel_mode = mode end,
	}
end

helpers.describe("HS-012 real keep-awake pause child", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains keep-awake intent after timer cleanup " .. mode, function()
			local ctx = load_real_keep_awake_owner()
			helpers.assert_true(ctx.system.toggle_awake())
			helpers.assert_true(ctx.system.is_awake_active())
			ctx.set_cancel_mode(mode)
			helpers.assert_eq(ctx.system.pause_awake(), false)
			helpers.assert_eq(ctx.system.is_awake_active(), false)
			ctx.set_cancel_mode("true")
			helpers.assert_true(ctx.system.pause_awake())
			helpers.assert_true(ctx.system.resume_awake())
			helpers.assert_true(ctx.system.is_awake_active(),
				"the original keep-awake session must survive cleanup retry")
			helpers.assert_true(ctx.system.resume_awake(),
				"duplicate resume must not toggle the restored session off")
			helpers.assert_true(ctx.system.is_awake_active())
		end)

		helpers.it("retains keep-awake intent after timer rearm " .. mode, function()
			local ctx = load_real_keep_awake_owner()
			helpers.assert_true(ctx.system.toggle_awake())
			helpers.assert_true(ctx.system.pause_awake())
			ctx.set_arm_mode(mode)
			helpers.assert_eq(ctx.system.resume_awake(), false)
			helpers.assert_eq(ctx.system.is_awake_active(), false)
			ctx.set_arm_mode("true")
			helpers.assert_true(ctx.system.resume_awake())
			helpers.assert_true(ctx.system.is_awake_active(),
				"timer construction refusal must leave a retryable restore intent")
		end)
	end
end)

local function load_real_shortcut_delivery_owner()
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	hs_stub.application.frontmostApplication = function()
		return { title = function() return "Fixture" end }
	end

	local handles = {}
	local wrap_handles = {}
	local delete_mode = "true"
	local lock_calls = 0
	local wrap_ax_calls = 0
	local function make_handle(callback, key, before_delete)
		local handle = { callback = callback, key = key, deleted = false, delete_calls = 0 }
		function handle:delete()
			self.delete_calls = self.delete_calls + 1
			if before_delete then before_delete(self) end
			if delete_mode == "throw" then error("hotkey delete exploded") end
			if delete_mode == "false" then return false end
			if delete_mode == "nil" then return nil end
			self.deleted = true
			return true
		end
		handles[#handles + 1] = handle
		return handle
	end
	hs_stub.hotkey.bind = function(_, key, callback)
		return make_handle(callback, key)
	end

	local function noop() return true end
	local function install_child_lifecycle(target, names)
		local paused = false
		target[names.pause] = function() paused = true; return true end
		target[names.resume] = function() paused = false; return true end
		target[names.stop] = function() paused = true; return true end
		target[names.is_paused] = function() return paused end
		target[names.has_pending] = function() return false end
	end
	local function make_wrap_handle(getter)
		local delivering = true
		local handle = make_handle(function()
			if not delivering then return false end
			wrap_ax_calls = wrap_ax_calls + 1
			if type(getter) == "function" then getter() end
			return false
		end, "wrap", function()
			delivering = false
		end)
		wrap_handles[#wrap_handles + 1] = handle
		return handle
	end
	local system_actions = setmetatable({
		bind_instant_screenshot = function() return make_handle(noop, "at_hash") end,
		bind_layer_scroll = function() return make_handle(noop, "layer_scroll") end,
		bind_wrap_text_if_selected = make_wrap_handle,
		bind_cmd_star = function() return make_handle(noop, "cmd_star") end,
		pause_awake = noop,
		resume_awake = noop,
		stop_awake = noop,
		lock_screen = function()
			lock_calls = lock_calls + 1
			return true
		end,
	}, { __index = function() return noop end })
	local inert_actions = setmetatable({}, { __index = function() return noop end })
	install_child_lifecycle(system_actions, {
		pause = "pause_mouse_actions",
		resume = "resume_mouse_actions",
		stop = "stop_mouse_actions",
		is_paused = "is_mouse_actions_paused",
		has_pending = "has_pending_mouse_action",
	})
	install_child_lifecycle(system_actions, {
		pause = "pause_pixel_actions",
		resume = "resume_pixel_actions",
		stop = "stop_pixel_actions",
		is_paused = "is_pixel_actions_paused",
		has_pending = "has_pending_pixel_action",
	})
	local screenshot_claims = {}
	system_actions.pause_screenshot_actions = function(parent)
		screenshot_claims[parent] = true
		return true
	end
	system_actions.resume_screenshot_actions = function(parent)
		screenshot_claims[parent] = nil
		return true
	end
	system_actions.stop_screenshot_actions = function(parent)
		screenshot_claims[parent] = true
		return true
	end
	system_actions.has_screenshot_pause_claim = function(parent)
		return screenshot_claims[parent] == true
	end
	system_actions.has_pending_screenshot_action = function() return false end
	install_child_lifecycle(inert_actions, {
		pause = "pause_text_actions",
		resume = "resume_text_actions",
		stop = "stop_text_actions",
		is_paused = "is_text_actions_paused",
		has_pending = "has_pending_text_action",
	})
	install_child_lifecycle(inert_actions, {
		pause = "pause_apps_actions",
		resume = "resume_apps_actions",
		stop = "stop_apps_actions",
		is_paused = "is_apps_actions_paused",
		has_pending = "has_pending_apps_action",
	})
	package.loaded["modules.shortcuts.actions.system"] = system_actions
	package.loaded["modules.shortcuts.actions.text"] = inert_actions
	package.loaded["modules.shortcuts.actions.apps"] = inert_actions
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "https://example.invalid" end,
	}
	package.loaded["modules.keylogger"] = { log_shortcut = function() return true end }
	reset_module("modules.shortcuts.bindings")
	local bindings = require("modules.shortcuts.bindings")

	return {
		bindings = bindings,
		handles = handles,
		wrap_handles = wrap_handles,
		get_lock_calls = function() return lock_calls end,
		get_wrap_ax_calls = function() return wrap_ax_calls end,
		set_delete_mode = function(mode) delete_mode = mode end,
		latest_callback = function(key)
			for index = #handles, 1, -1 do
				if handles[index].key == key then return handles[index].callback end
			end
		end,
	}
end

helpers.describe("HS-012 real shortcut delivery fence", function()
	helpers.it("updates the live wrap preference without replacing its active native owner", function()
		local ctx = load_real_shortcut_delivery_owner()
		local first_getter_calls = 0
		local second_getter_calls = 0
		helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
			first_getter_calls = first_getter_calls + 1
			return {}
		end))
		helpers.assert_true(ctx.bindings.start())
		helpers.assert_eq(#ctx.wrap_handles, 1)
		local owner = ctx.wrap_handles[1]
		owner.callback()
		helpers.assert_eq(ctx.get_wrap_ax_calls(), 1)
		helpers.assert_eq(first_getter_calls, 1)

		helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
			second_getter_calls = second_getter_calls + 1
			return {}
		end))
		helpers.assert_eq(#ctx.wrap_handles, 1,
			"a live preference update must not acquire a replacement eventtap")
		helpers.assert_eq(owner.delete_calls, 0,
			"a live preference update must not tear down the active eventtap")
		owner.callback()
		helpers.assert_eq(ctx.get_wrap_ax_calls(), 2)
		helpers.assert_eq(first_getter_calls, 1)
		helpers.assert_eq(second_getter_calls, 1,
			"the unchanged native callback must resolve the newly published getter")

		helpers.assert_true(ctx.bindings.stop())
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("keeps a retained native hotkey inert after rollback delete " .. mode, function()
			local ctx = load_real_shortcut_delivery_owner()
			helpers.assert_true(ctx.bindings.start())
			local initial_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(initial_callback)
			initial_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 1,
				"positive control proves the real direct hotkey callback is live")

			local script_control = load_inventory_context({
				shortcuts = {
					is_bindings_started = ctx.bindings.is_started,
					pause_bindings = ctx.bindings.pause,
					resume_bindings = ctx.bindings.resume_after_pause,
					release_bindings_pause_claim = function() return true end,
				},
				fail_owner = "remote_warmup",
				fail_mode = "false",
				fail_direction = "resume",
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())

			ctx.set_delete_mode(mode)
			helpers.assert_eq(script_control.resume_all(), false,
				"a later resume refusal must roll the real bindings owner back")
			helpers.assert_true(script_control.is_paused())
			local retained_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(retained_callback)
			retained_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 1,
				"a retained native callback must be logically fenced under PAUSED")

			ctx.set_delete_mode("true")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			local resumed_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(resumed_callback)
			resumed_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 2,
				"delivery must reopen exactly after the successful global resume")
			helpers.assert_true(ctx.bindings.stop())
			script_control.stop()
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact wrap owner when menu rewiring follows rollback delete " .. mode, function()
			local ctx = load_real_shortcut_delivery_owner()
			local getter_calls = 0
			helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
				getter_calls = getter_calls + 1
				return {}
			end))
			helpers.assert_true(ctx.bindings.start())
			helpers.assert_eq(#ctx.wrap_handles, 1)
			local first_owner = ctx.wrap_handles[1]

			local script_control = load_inventory_context({
				shortcuts = {
					is_bindings_started = ctx.bindings.is_started,
					pause_bindings = ctx.bindings.pause,
					resume_bindings = ctx.bindings.resume_after_pause,
					release_bindings_pause_claim = function() return true end,
				},
				fail_owner = "remote_warmup",
				fail_mode = "false",
				fail_direction = "resume",
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(first_owner.deleted,
				"the owner active before PAUSE must settle before the state is published")

			ctx.set_delete_mode(mode)
			helpers.assert_eq(script_control.resume_all(), false,
				"the later owner refusal must roll the newly resumed bindings back")
			helpers.assert_true(script_control.is_paused())
			helpers.assert_eq(#ctx.wrap_handles, 2)
			local retained_owner = ctx.wrap_handles[2]
			helpers.assert_eq(retained_owner.delete_calls, 1,
				"rollback must retain the exact native owner whose delete did not settle")
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0,
				"the retained callback must already be logically fenced under PAUSED")

			local replacement_getter_calls = 0
			helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
				replacement_getter_calls = replacement_getter_calls + 1
				return {}
			end), "menu rewiring may publish preference state while native cleanup is pending")
			helpers.assert_eq(#ctx.wrap_handles, 2,
				"menu rewiring under PAUSED must not acquire a sibling eventtap")
			helpers.assert_eq(retained_owner.delete_calls, 1,
				"the setter must leave the retained cleanup capability to ScriptControl")
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0)
			helpers.assert_eq(getter_calls, 0)
			helpers.assert_eq(replacement_getter_calls, 0)

			ctx.set_delete_mode("true")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(retained_owner.delete_calls, 2,
				"retry must settle the same retained owner before acquiring its successor")
			helpers.assert_true(retained_owner.deleted)
			helpers.assert_eq(#ctx.wrap_handles, 3)
			local resumed_owner = ctx.wrap_handles[3]
			helpers.assert_true(resumed_owner ~= retained_owner)
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0,
				"the old owner stays inert after RESUMED")
			resumed_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 1,
				"exactly the post-commit owner may reach the AX path")
			helpers.assert_eq(getter_calls, 0)
			helpers.assert_eq(replacement_getter_calls, 1,
				"the deferred preference must be installed on the sole successor")

			helpers.assert_true(ctx.bindings.stop())
			script_control.stop()
		end)
	end
end)

local function load_prediction_registry()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	reset_module("ui.menu.menu_llm.prediction_lock_registry")
	local state = { llm_enabled = true }
	local runtime = true
	local mode = "true"
	local calls = {}
	local keymap = {
		get_llm_enabled = function() return runtime end,
		set_llm_enabled = function(enabled)
			calls[#calls + 1] = enabled
			if mode == "false_no_mutation" then return false end
			if mode == "nil_no_mutation" then return nil end
			if mode == "throw_no_mutation" then error("registry setter exploded before mutation") end
			runtime = enabled == true
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("registry setter exploded") end
			return true
		end,
	}
	local registry = require("ui.menu.menu_llm.prediction_lock_registry").new({
		state = state,
		keymap = keymap,
	})
	return {
		registry = registry,
		state = state,
		calls = calls,
		get_runtime = function() return runtime end,
		set_runtime = function(value) runtime = value == true end,
		set_mode = function(value) mode = value end,
	}
end

helpers.describe("HS-012 shared prediction-lock registry", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains acquisition debt after " .. mode .. " without mutation", function()
			local ctx = load_prediction_registry()
			ctx.set_mode(mode .. "_no_mutation")
			helpers.assert_eq(ctx.registry.acquire("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.ensure_locked("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
		end)

		helpers.it("compensates mutate-then-" .. mode .. " acquisition", function()
			local ctx = load_prediction_registry()
			ctx.set_mode(mode)
			helpers.assert_eq(ctx.registry.acquire("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
		end)
	end

	helpers.it("keeps overlapping startup and model leases locked in both release orders", function()
		for _, order in ipairs({
			{ "startup", "model" },
			{ "model", "startup" },
		}) do
			local ctx = load_prediction_registry()
			helpers.assert_true(ctx.registry.acquire("startup"))
			helpers.assert_true(ctx.registry.acquire("model"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release(order[1]))
			helpers.assert_eq(ctx.get_runtime(), false,
				"the first completion may not expose the remaining async owner")
			helpers.assert_true(ctx.registry.release(order[2]))
			helpers.assert_eq(ctx.get_runtime(), true)
			helpers.assert_true(ctx.registry.release(order[2]),
				"duplicate terminal delivery is an exact no-op")
		end
	end)

	helpers.it("routes OFF-to-ON preference writes through overlapping leases", function()
		local ctx = load_prediction_registry()
		helpers.assert_true(ctx.registry.acquire("startup"))
		helpers.assert_true(ctx.registry.acquire("model"))
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		ctx.state.llm_enabled = true
		helpers.assert_true(ctx.registry.apply_preference(true))
		helpers.assert_eq(ctx.get_runtime(), false,
			"enabled preference intent must remain parked while leases exist")
		ctx.set_runtime(true)
		helpers.assert_true(ctx.registry.release("startup"))
		helpers.assert_eq(ctx.get_runtime(), false,
			"non-final release must reassert against a bypassing writer")
		helpers.assert_true(ctx.registry.release("model"))
		helpers.assert_eq(ctx.get_runtime(), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the last lease after mutate-then-" .. mode .. " restore", function()
			local ctx = load_prediction_registry()
			helpers.assert_true(ctx.registry.acquire("startup"))
			ctx.set_mode(mode)
			helpers.assert_eq(ctx.registry.release("startup"), false)
			helpers.assert_true(ctx.registry.held("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.set_mode("true")
			helpers.assert_true(ctx.registry.ensure_locked("startup"))
			helpers.assert_eq(ctx.get_runtime(), false)
			helpers.assert_true(ctx.registry.release("startup"))
			helpers.assert_eq(ctx.get_runtime(), true)
	end)
	end

	helpers.it("never resurrects a preference disabled while a lease is held", function()
		local ctx = load_prediction_registry()
		helpers.assert_true(ctx.registry.acquire("model"))
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		helpers.assert_true(ctx.registry.release("model"))
		helpers.assert_eq(ctx.get_runtime(), false)
	end)
end)

helpers.describe("HS-012 real warmup-controller pause snapshot", function()
	local function load_controller()
		local handles = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function() return 1 end }
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_, callback)
				local handle = { callback = callback, live = true }
				handles[#handles + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.live = false
				return true
			end,
		}
		reset_module("modules.llm.warmup_controller")
		local controller = require("modules.llm.warmup_controller")
		helpers.assert_true(controller.init({
			core_llm = {
				get_current_model = function() return "model" end,
				get_backend = function() return "mlx" end,
				get_active_profile = function() return {} end,
				is_backend_ready = function() return false end,
				warmup_model = function() return true end,
			},
			get_llm_enabled = function() return true end,
		}))
		return controller, handles
	end

	helpers.it("does not invent work for a controller inactive before pause", function()
		local controller, handles = load_controller()
		helpers.assert_true(controller.pause_warmup())
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 0)
	end)

	helpers.it("re-arms one active retry intent exactly once", function()
		local controller, handles = load_controller()
		helpers.assert_true(controller.schedule_warmup_with_retry("positive control"))
		helpers.assert_eq(#handles, 1)
		helpers.assert_true(controller.pause_warmup())
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 2)
		helpers.assert_true(controller.resume_warmup())
		helpers.assert_eq(#handles, 2)
	end)
end)

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

helpers.describe("HS-012 real startup timer and manager ownership", function()
	for _, delay in ipairs({ 1, 3 }) do
		for _, mode in ipairs({ "false", "nil", "throw", "sync" }) do
			helpers.it("compensates startup timer " .. tostring(delay)
				.. " acquisition " .. mode, function()
				local ctx = load_real_startup_owner(nil, {
					arm_mode = mode,
					arm_fail_delay = delay,
					arm_failures = 1,
				})
				helpers.assert_eq(ctx.startup_result, false)
				helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
					"timer acquisition refusal must restore the startup lease")
				for _, timer in ipairs(ctx.timers) do timer.fn() end
				helpers.assert_eq(#ctx.probes, 0,
					"failed and synchronous timer acquisitions must leave late work fenced")
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates startup probe dispatch " .. mode .. " exactly once", function()
			local ctx = load_real_startup_owner(nil, { dispatch_mode = mode })
			helpers.assert_true(ctx.startup_result)
			fire_timer_delay(ctx, 1)
			helpers.assert_eq(#ctx.probes, 1)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
			local probe = ctx.probes[1]
			probe.on_ok()
			probe.on_fail("late")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"late or duplicate manager terminals may not restore twice")
			helpers.assert_eq(ctx.state.llm_enabled, true)
		end)

		helpers.it("discards synchronous startup failure before " .. mode
			.. " dispatch refusal", function()
			local ctx = load_real_startup_owner(nil, {
				dispatch_mode = mode,
				sync_terminal = "fail",
			})
			local saves_before = ctx.get_saves()
			local menu_before = ctx.get_menu_updates()
			fire_timer_delay(ctx, 1)
			helpers.assert_eq(ctx.state.llm_enabled, true,
				"a pre-commit terminal may not disable the live preference")
			helpers.assert_eq(ctx.get_saves(), saves_before)
			helpers.assert_eq(ctx.get_menu_updates(), menu_before)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences mutate-then-" .. mode .. " download reattachment", function()
			local active = false
			local parked = false
			local reattach_opts = nil
			local ctx = load_real_startup_owner(nil, {
				reattach_download = function(_, opts)
					active = true
					reattach_opts = opts
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					error("reattach dispatch exploded")
				end,
				has_reattached_download = function() return active end,
				pause_reattached_download = function() parked = true; return true end,
				resume_reattached_download = function(opts)
					parked = false
					reattach_opts = opts
					return true
				end,
			})
			local original_open = io.open
			local original_decode = hs.json.decode
			io.open = function(path, access)
				if path == "/tmp/hs_mlx_active_download.json" then
					return {
						read = function() return "fixture" end,
						close = function() return true end,
					}
				end
				return original_open(path, access)
			end
			hs.json.decode = function()
				return { log_path = "/fixture.log", model = "fixture" }
			end
			fire_timer_delay(ctx, 0.5)
			io.open = original_open
			hs.json.decode = original_decode
			helpers.assert_true(active)
			helpers.assert_true(parked,
				"a refused reattach that created work must run its parking inverse")
			helpers.assert_eq(reattach_opts.is_current(), false,
				"refusal must revoke manager callbacks before compensation")

			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			ctx.set_paused(true)
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(parked, false)
			helpers.assert_true(reattach_opts.resume_is_current(),
				"the local owner may resume inside the still-unpublished transaction")
			helpers.assert_eq(reattach_opts.is_current(), false,
				"business callbacks must remain fenced while global state is still PAUSED")
			ctx.set_paused(false)
			helpers.assert_true(reattach_opts.is_current(),
				"only the committed global RESUMED state may re-authorize business callbacks")
		end)
	end

	for _, probe_mode in ipairs({ "nil", "throw" }) do
		helpers.it("retains ambiguous reattachment ownership after probe "
			.. probe_mode, function()
			local pause_calls = 0
			local resume_calls = 0
			local ctx = load_real_startup_owner(nil, {
				reattach_download = function() return false end,
				has_reattached_download = function()
					if probe_mode == "throw" then error("reattach ownership probe exploded") end
					return nil
				end,
				pause_reattached_download = function()
					pause_calls = pause_calls + 1
					return true
				end,
				resume_reattached_download = function()
					resume_calls = resume_calls + 1
					return true
				end,
			})
			local original_open = io.open
			local original_decode = hs.json.decode
			io.open = function(path, access)
				if path == "/tmp/hs_mlx_active_download.json" then
					return {
						read = function() return "fixture" end,
						close = function() return true end,
					}
				end
				return original_open(path, access)
			end
			hs.json.decode = function()
				return { log_path = "/fixture.log", model = "fixture" }
			end
			fire_timer_delay(ctx, 0.5)
			io.open = original_open
			hs.json.decode = original_decode

			helpers.assert_eq(pause_calls, 1,
				"an unreadable ownership probe must compensate the ambiguous owner")
			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			helpers.assert_eq(pause_calls, 2,
				"the compensated owner must remain in the exact global pause snapshot")
			ctx.set_paused(true)
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(resume_calls, 1)
		end)
	end

	helpers.it("does not retain a reattachment that settles synchronously", function()
		local pause_calls = 0
		local resume_calls = 0
		local terminal_calls = 0
		local ctx = load_real_startup_owner(nil, {
			reattach_download = function(_, opts)
				terminal_calls = terminal_calls + 1
				helpers.assert_true(opts.on_terminal())
				terminal_calls = terminal_calls + 1
				helpers.assert_true(opts.on_terminal())
				return true
			end,
			has_reattached_download = function() return false end,
			pause_reattached_download = function()
				pause_calls = pause_calls + 1
				return true
			end,
			resume_reattached_download = function()
				resume_calls = resume_calls + 1
				return true
			end,
		})
		local original_open = io.open
		local original_decode = hs.json.decode
		io.open = function(path, access)
			if path == "/tmp/hs_mlx_active_download.json" then
				return {
					read = function() return "fixture" end,
					close = function() return true end,
				}
			end
			return original_open(path, access)
		end
		hs.json.decode = function()
			return { log_path = "/fixture.log", model = "fixture" }
		end
		fire_timer_delay(ctx, 0.5)
		io.open = original_open
		hs.json.decode = original_decode
		helpers.assert_eq(terminal_calls, 2)

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(pause_calls, 0,
			"a synchronously settled owner must not be snapshotted")
		helpers.assert_eq(resume_calls, 0,
			"duplicate terminals must not create a phantom resume intent")
	end)

	helpers.it("absorbs an already-dispatched stale failure after pause", function()
		local ctx = load_real_startup_owner()
		fire_timer_delay(ctx, 1)
		local probe = ctx.probes[1]
		helpers.assert_not_nil(probe)
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		probe.on_fail("stale")
		helpers.assert_eq(ctx.state.llm_enabled, true)
		helpers.assert_eq(ctx.get_saves(), 0)
		helpers.assert_eq(ctx.get_menu_updates(), 0)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"a stale manager cancellation may not disable or unlock during PAUSED")
	end)

	for _, delay in ipairs({ 1, 3 }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains startup lease after mutate-then-" .. mode
				.. " success restoration on timer " .. tostring(delay), function()
				local ctx = load_real_startup_owner()
				fire_timer_delay(ctx, delay)
				ctx.set_prediction_mode(mode)
				helpers.assert_eq(ctx.probes[1].on_ok(), false)
				helpers.assert_eq(ctx.get_prediction_state(), true)
				ctx.set_epoch(1)
				ctx.set_prediction_mode("true")
				helpers.assert_true(ctx.owner.pause())
				helpers.assert_eq(ctx.get_prediction_state(), false)
				ctx.set_paused(true)
				ctx.set_epoch(2)
				helpers.assert_true(ctx.owner.resume())
				helpers.assert_eq(ctx.get_prediction_state(), true)
				ctx.probes[1].on_ok()
				helpers.assert_eq(ctx.get_prediction_state(), true,
					"duplicate startup success may not consume or restore a second lease")
			end)
		end
	end

	helpers.it("runs a startup request made during PAUSED exactly once on resume", function()
		local ctx = load_real_startup_owner(nil, { initial_paused = true })
		helpers.assert_true(ctx.startup_result)
		helpers.assert_eq(#ctx.timers, 0,
			"late construction must defer every startup timer while PAUSED")
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_eq(#ctx.timers, 3)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(#ctx.timers, 3,
			"duplicate resume must not replay the deferred startup request")
	end)

	helpers.it("keeps the startup lease when a later resume owner rolls back", function()
		local ctx = load_real_startup_owner()
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(ctx.get_prediction_state(), false,
			"a restarted startup cycle must retain its lease until its own terminal")
		helpers.assert_true(ctx.owner.pause(),
			"same-epoch rollback must reuse the original had-lock snapshot")
		helpers.assert_eq(ctx.get_prediction_state(), false)
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_eq(ctx.get_prediction_state(), false)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"pause/resume rollback may not expose either replacement cycle")
		ctx.set_paused(false)
		local replacement = fire_timer_delay(ctx, 1, 6)
		helpers.assert_not_nil(replacement)
		ctx.probes[#ctx.probes].on_ok()
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"the committed replacement terminal must restore the lease exactly once")
	end)

	helpers.it("retains startup work intent across failed inverse and fresh pause retry", function()
		local ctx = load_real_startup_owner()
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		ctx.set_arm_failure("false", 1, 1)
		helpers.assert_eq(ctx.owner.resume(), false)
		ctx.set_epoch(3)
		ctx.set_arm_failure("true", nil, 0)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_epoch(4)
		helpers.assert_true(ctx.owner.resume())
		local replacement = fire_timer_delay(ctx, 1, 5)
		helpers.assert_not_nil(replacement,
			"the original active startup cycle must survive a new pause epoch")
	end)

	helpers.it("invalidates already-dispatched probes and re-arms only the committed cycle", function()
		local ctx = load_real_startup_owner()
		helpers.assert_eq(#ctx.timers, 3,
			"reattach, primary, and backup timers must be owned")
		fire_timer_delay(ctx, 1)
		fire_timer_delay(ctx, 3)
		helpers.assert_eq(#ctx.probes, 2,
			"positive control must dispatch both real startup probes")

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)

		local native_starts = 0
		for index = 1, 2 do
			local old_probe = ctx.probes[index]
			if old_probe.opts.is_current() then
				native_starts = native_starts + 1
				old_probe.on_ok()
			end
		end
		helpers.assert_eq(native_starts, 0,
			"manager-side is_current must fence probes dispatched before pause")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }),
			"the startup lock remains owned while the replacement cycle is pending")

		local new_primary = fire_timer_delay(ctx, 1, 4)
		helpers.assert_not_nil(new_primary,
			"resume must re-arm the primary timer from the committed cycle")
		local current_probe = ctx.probes[#ctx.probes]
		helpers.assert_true(current_probe.opts.is_current())
		native_starts = native_starts + 1
		current_probe.on_ok()
		helpers.assert_eq(native_starts, 1)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"the real startup owner must consume its prediction lock once")
	end)

	helpers.it("replays one startup deferred during PAUSED after a later owner refuses resume", function()
		local script_control = load_inventory_context({
			skip_dynamic_owners = {
				llm_startup = true,
				llm_model_switcher = true,
			},
		})
		helpers.assert_true(script_control.pause_all())
		helpers.assert_true(script_control.is_paused())

		local prediction_calls = {}
		local ctx = load_real_startup_owner(nil, {
			script_control = script_control,
			prediction_calls = prediction_calls,
		})
		helpers.assert_true(ctx.startup_result,
			"construction during PAUSED must accept and retain startup intent")
		helpers.assert_eq(#ctx.timers, 0,
			"deferred startup may not arm timers before a resume attempt")

		local later_resume_calls = 0
		helpers.assert_true(script_control.register_pause_owner("llm_model_switcher", {
			pause = function() return true end,
			resume = function()
				later_resume_calls = later_resume_calls + 1
				return later_resume_calls > 1
			end,
		}))
		helpers.assert_eq(script_control.resume_all(), false,
			"the later registered owner refusal must roll the real startup owner back")
		helpers.assert_true(script_control.is_paused())
		helpers.assert_true(helpers.deep_equal(prediction_calls, { false }),
			"same-epoch rollback must retain and reassert the startup prediction lease")
		helpers.assert_eq(#ctx.timers, 3,
			"the refused attempt must own the exact reattach, primary, and backup timers")
		for _, timer in ipairs(ctx.timers) do timer.fn() end
		helpers.assert_eq(#ctx.probes, 0,
			"timers from the rolled-back deferred attempt must remain fenced")

		local first_retry_timer = #ctx.timers + 1
		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(#ctx.timers, 6,
			"the retained startup intent must re-arm exactly one replacement timer set")
		helpers.assert_true(helpers.deep_equal(prediction_calls, { false, false }),
			"retry must reassert the same retained lease instead of acquiring a duplicate")
		local primary = fire_timer_delay(ctx, 1, first_retry_timer)
		helpers.assert_not_nil(primary)
		helpers.assert_eq(#ctx.probes, 1,
			"the successful retry must launch the deferred requirements cycle once")

		helpers.assert_true(script_control.resume_all())
		helpers.assert_eq(#ctx.timers, 6,
			"duplicate RESUMED delivery may not replay the consumed startup request")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps both startup timers inert when stop returns " .. mode, function()
			local ctx = load_real_startup_owner(mode)
			ctx.set_epoch(1)
			helpers.assert_eq(ctx.owner.pause(), false,
				"both timer cleanup refusals must reject the pause owner")
			for _, timer in ipairs(ctx.timers) do timer.fn() end
			helpers.assert_eq(#ctx.probes, 0,
				"even a native late delivery must be fenced before fallible stop")
			ctx.set_stop_mode("true")
			ctx.set_epoch(2)
			helpers.assert_true(ctx.owner.resume(),
				"retained exact timers must be retryable before re-arm")
			helpers.assert_true(#ctx.timers >= 6,
				"only after cleanup settles may the prior timer set be re-armed")
		end)
	end
end)

helpers.describe("HS-012 real reattached MLX work fence", function()
	helpers.it("parks poll, stream, and terminal effects until global RESUMED commits", function()
		local timers = {}
		local timer_stop_mode = "true"
		local native_task = nil
		local native_task_running = false
		local icon_updates = 0
		local window_updates = 0
		local terminal_updates = 0
		local exit_available = false
		reset_module("tests.stubs.hs")
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		hs_stub.timer.new = function(_, callback)
			local running = false
			local native = { callback = callback }
			function native:start()
				running = true
				return self
			end
			function native:running() return running end
			function native:stop()
				if timer_stop_mode == "throw" then error("reattach timer stop exploded") end
				if timer_stop_mode == "false" then return false end
				if timer_stop_mode == "nil" then return nil end
				running = false
				return self
			end
			timers[#timers + 1] = native
			return native
		end
		reset_module("adapters.timer_scheduler")
		require("adapters.timer_scheduler")
		package.loaded["adapters.task_lifecycle"] = {
			native = function(_, _, on_done, on_stream)
				native_task = {
					on_done = on_done,
					on_stream = on_stream,
					terminate = function()
						native_task_running = false
						return true
					end,
					isRunning = function() return native_task_running end,
				}
				return native_task
			end,
			start = function()
				native_task_running = true
				return true
			end,
		}
		package.loaded["ui.download_window"] = {
			show = function() return true end,
			update = function() window_updates = window_updates + 1; return true end,
			complete = function()
				terminal_updates = terminal_updates + 1
				return true
			end,
		}
		reset_module("ui.menu.menu_llm.models_manager_mlx_download")
		local obj = {}
		require("ui.menu.menu_llm.models_manager_mlx_download").install({
			obj = obj,
			deps = {
				active_tasks = {},
				update_icon = function()
					icon_updates = icon_updates + 1
					return true
				end,
			},
			presets = { {
				families = { {
					models = { {
						name = "fixture",
						hardware_requirements = { mlx = { download_gb = 1 } },
					} },
				} },
			} },
			project_venv_python_escaped = "python",
			invalidate_installed_cache = function() return true end,
		})
		local original_open = io.open
		io.open = function(path, access)
			if path == "/definitely-missing-hs012.exit" then
				if not exit_available then return nil end
				return {
					read = function() return "0" end,
					close = function() return true end,
				}
			end
			return original_open(path, access)
		end
		local authorized = true
		helpers.assert_true(obj.reattach_download({
			model = "fixture",
			log_path = "/definitely-missing-hs012.log",
			exit_path = "/definitely-missing-hs012.exit",
		}, {
			is_current = function() return authorized end,
		}))
		helpers.assert_not_nil(native_task)
		helpers.assert_eq(#timers, 1)
		local active_poll_index = 1
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			timer_stop_mode = mode
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index,
				mode .. " terminal-stop refusal may not create a poll successor")
			timer_stop_mode = "true"
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index + 1,
				mode .. " settlement must release exactly one deferred poll callback")
			timers[active_poll_index].callback()
			helpers.assert_eq(#timers, active_poll_index + 1,
				mode .. " duplicate native delivery must remain inert")
			active_poll_index = active_poll_index + 1
		end
		local icon_before = icon_updates
		local window_before = window_updates

		helpers.assert_true(obj.pause_reattached_download())
		authorized = false
		timers[active_poll_index].callback()
		native_task.on_stream(nil, "__BYTES__:500000000", "")
		helpers.assert_eq(icon_updates, icon_before)
		helpers.assert_eq(window_updates, window_before,
			"already-dispatched tail output must be inert while parked")

		authorized = true
		helpers.assert_true(obj.resume_reattached_download({
			is_current = function() return authorized end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 1,
			"the poll delivery parked during pause must be re-armed once")
		native_task.on_stream(nil, "__BYTES__:500000000", "")
		helpers.assert_true(icon_updates > icon_before)
		helpers.assert_true(window_updates > window_before,
			"positive resume control proves the same real callback can publish")

		helpers.assert_true(obj.pause_reattached_download())
		authorized = false
		exit_available = true
		native_task.on_done()
		helpers.assert_eq(window_updates, window_before + 1,
			"late tail completion must remain parked without terminal UI effects")
		helpers.assert_eq(terminal_updates, 0)

		local globally_resumed = false
		helpers.assert_true(obj.resume_reattached_download({
			resume_is_current = function() return true end,
			is_current = function() return globally_resumed end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 2,
			"tail completion must cross an owned post-resume commit timer")
		helpers.assert_eq(terminal_updates, 0,
			"local owner resume may not publish terminal UI while ScriptControl is PAUSED")

		-- Simulate a later ScriptControl owner refusing in the same resume epoch.
		helpers.assert_true(obj.pause_reattached_download())
		timers[active_poll_index + 2].callback()
		helpers.assert_eq(terminal_updates, 0,
			"the post-resume timer must remain inert after same-epoch rollback")

		helpers.assert_true(obj.resume_reattached_download({
			resume_is_current = function() return true end,
			is_current = function() return globally_resumed end,
		}))
		helpers.assert_eq(#timers, active_poll_index + 3,
			"retry must re-arm the exact parked commit delivery once")
		helpers.assert_eq(terminal_updates, 0)
		globally_resumed = true
		timers[active_poll_index + 3].callback()
		helpers.assert_eq(terminal_updates, 1,
			"only the globally committed retry may publish terminal UI")
		timers[active_poll_index + 3].callback()
		helpers.assert_eq(terminal_updates, 1,
			"duplicate native delivery may not repeat the terminal effect")
		io.open = original_open
	end)
end)

local function load_real_model_switch_owner(options)
	options = options or {}
	local epoch = 0
	local paused = false
	local owner = nil
	local state = options.state or {
		llm_backend = "mlx",
		llm_enabled = true,
		llm_active_profile = "basic",
		llm_model = "old-model",
	}
	local control = {
		get_pause_epoch = function() return epoch end,
		is_paused = function() return paused end,
		register_pause_owner = function(name, candidate)
			helpers.assert_eq(name, "llm_model_switcher")
			owner = candidate
			return true
		end,
	}
	local prediction_box = options.prediction_box or { value = true }
	local prediction_calls = options.prediction_calls or {}
	local prediction_mode = options.prediction_mode or "true"
	local probe = nil
	local dispatch_calls = 0
	local requirement_owner = {}
	local models_mgr = {
		create_requirement_owner = function(label)
			helpers.assert_eq(label, "model_switcher")
			return requirement_owner
		end,
		pause_requirements = function(owner_identity)
			helpers.assert_true(owner_identity == requirement_owner,
				"model switching must join only its exact requirement capability")
			return true
		end,
		check_requirements = function(model, on_ok, on_fail, opts)
			helpers.assert_true(opts.requirement_owner == requirement_owner,
				"model probes must carry their opaque requirement capability")
			dispatch_calls = dispatch_calls + 1
			probe = { model = model, on_ok = on_ok, on_fail = on_fail, opts = opts }
			if options.sync_terminal == "ok" then on_ok() end
			if options.sync_terminal == "fail" then on_fail("sync") end
			if options.dispatch_mode == "false" then return false end
			if options.dispatch_mode == "nil" then return nil end
			if options.dispatch_mode == "throw" then error("model dispatch exploded") end
			return true
		end,
		get_presets = function() return {} end,
		get_model_info = function() return {} end,
		get_actual_model_name = function(name) return name end,
	}
	local keymap = options.keymap or {
		get_llm_enabled = function() return prediction_box.value end,
		set_llm_enabled = function(enabled)
			prediction_box.value = enabled == true
			prediction_calls[#prediction_calls + 1] = enabled
			if prediction_mode == "false" then return false end
			if prediction_mode == "nil" then return nil end
			if prediction_mode == "throw" then error("prediction setter exploded") end
			return true
		end,
		set_llm_model = function() return true end,
		set_llm_display_model_name = function() return true end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
	package.loaded["infra.notifications"] = { notify = function() return true end }
	package.loaded["ui.menu.menu_llm.profile_label"] = {
		format = function(label) return label end,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_num_predictions = 1 },
		get_active_profile = function() return { id = "basic" } end,
		set_active_profile = function() return true end,
		set_llm_model_mlx = function() return true end,
		set_llm_model_ollama = function() return true end,
	}
	reset_module("ui.menu.menu_llm.model_switcher")
	local ModelSwitcher = require("ui.menu.menu_llm.model_switcher")
	local switcher = ModelSwitcher.new({
		state = state,
		models_mgr = models_mgr,
		keymap = keymap,
		script_control = control,
		prediction_locks = options.prediction_locks,
		save_prefs = function() return true end,
		update_menu = function() return true end,
		runtime_gate = function() return paused ~= true end,
		pause_epoch = function() return epoch end,
	})
	helpers.assert_not_nil(owner)
	return {
		switcher = switcher,
		owner = owner,
		state = state,
		prediction_calls = prediction_calls,
		get_probe = function() return probe end,
		get_prediction_state = function() return keymap.get_llm_enabled() end,
		get_dispatch_calls = function() return dispatch_calls end,
		set_prediction_mode = function(value) prediction_mode = value end,
		set_epoch = function(value) epoch = value end,
		set_paused = function(value) paused = value == true end,
	}
end

helpers.describe("HS-012 real ordinary model-switch pause epoch", function()
	helpers.it("rejects switch and No Model before any mutation while PAUSED", function()
		local ctx = load_real_model_switch_owner()
		ctx.set_paused(true)
		helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
		helpers.assert_eq(ctx.switcher.disable_model(), false)
		helpers.assert_eq(ctx.get_dispatch_calls(), 0)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, {}),
			"paused preflight must run before prediction-lock acquisition")
		helpers.assert_eq(ctx.state.llm_model, "old-model")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("compensates a " .. mode .. " model requirements dispatch once", function()
			local ctx = load_real_model_switch_owner({ dispatch_mode = mode })
			helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"a refused dispatch must release the exact prediction lease")
			local probe = ctx.get_probe()
			helpers.assert_not_nil(probe,
				"the positive dispatch boundary must receive real continuations")
			probe.on_ok()
			probe.on_fail()
			helpers.assert_eq(ctx.state.llm_model, "old-model")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
				"late and duplicate terminals may not restore or publish twice")
		end)

		helpers.it("discards a synchronous success before " .. mode .. " dispatch refusal", function()
			local ctx = load_real_model_switch_owner({
				dispatch_mode = mode,
				sync_terminal = "ok",
			})
			helpers.assert_eq(ctx.switcher.switch_model("model-A"), false)
			helpers.assert_eq(ctx.state.llm_model, "old-model",
				"a synchronous callback cannot publish before dispatch ownership commits")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
			local probe = ctx.get_probe()
			probe.on_ok()
			probe.on_fail("late")
			helpers.assert_eq(ctx.state.llm_model, "old-model")
			helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		end)
	end

	helpers.it("delivers one synchronous success after dispatch acceptance", function()
		local ctx = load_real_model_switch_owner({ sync_terminal = "ok" })
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		helpers.assert_eq(ctx.state.llm_model, "model-A")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }))
		local probe = ctx.get_probe()
		probe.on_ok()
		probe.on_fail("late")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"duplicate synchronous and late terminals must settle once")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reasserts the model lock after mutate-then-" .. mode .. " resume", function()
			local ctx = load_real_model_switch_owner()
			helpers.assert_true(ctx.switcher.switch_model("model-A"))
			ctx.set_epoch(1)
			helpers.assert_true(ctx.owner.pause())
			ctx.set_paused(true)
			ctx.set_epoch(2)
			ctx.set_prediction_mode(mode)
			helpers.assert_eq(ctx.owner.resume(), false)
			helpers.assert_eq(ctx.get_prediction_state(), true,
				"the refusing enable mutates first in this adverse fixture")
			ctx.set_epoch(3)
			ctx.set_prediction_mode("true")
			helpers.assert_true(ctx.owner.pause(),
				"resume rollback must retain and reassert the same lease")
			helpers.assert_eq(ctx.get_prediction_state(), false)
			ctx.set_epoch(4)
			helpers.assert_true(ctx.owner.resume())
			helpers.assert_eq(ctx.get_prediction_state(), true)
		end)
	end

	helpers.it("abandons the old manager guard and restores its MLX lock exactly once", function()
		local ctx = load_real_model_switch_owner()
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		local probe = ctx.get_probe()
		helpers.assert_not_nil(probe)
		helpers.assert_true(probe.opts.is_current(),
			"positive control must prove the real manager guard starts current")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false }))

		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_eq(probe.opts.is_current(), false,
			"the manager-side operation token must remain stale after resume")
		probe.on_ok()
		helpers.assert_eq(ctx.state.llm_model, "old-model",
			"the abandoned model may never publish after the pause epoch")
		helpers.assert_true(ctx.owner.resume(),
			"duplicate resume delivery is an idempotent no-op")
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, true }),
			"one retained lock must produce exactly one successful restoration")
	end)

	helpers.it("does not resurrect predictions disabled in live preferences", function()
		local ctx = load_real_model_switch_owner()
		helpers.assert_true(ctx.switcher.switch_model("model-A"))
		ctx.set_epoch(1)
		helpers.assert_true(ctx.owner.pause())
		ctx.set_paused(true)
		ctx.state.llm_enabled = false
		ctx.set_epoch(2)
		helpers.assert_true(ctx.owner.resume())
		ctx.set_paused(false)
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, false }),
			"resume must exactly reassert the disabled preference before consuming its lease")
		ctx.state.llm_enabled = true
		helpers.assert_true(ctx.owner.resume())
		helpers.assert_true(helpers.deep_equal(ctx.prediction_calls, { false, false }),
			"a consumed disabled lock cannot be restored later by duplicate delivery")
	end)
end)

helpers.describe("HS-012 real startup/model shared prediction leases", function()
	local function build_overlap()
		local state = {
			llm_backend = "mlx",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "shared-model",
		}
		local runtime = true
		local calls = {}
		local keymap = {
			get_llm_enabled = function() return runtime end,
			set_llm_enabled = function(enabled)
				runtime = enabled == true
				calls[#calls + 1] = enabled
				return true
			end,
			set_llm_backend_name = function() return true end,
			set_llm_model = function() return true end,
			set_llm_display_model_name = function() return true end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		reset_module("ui.menu.menu_llm.prediction_lock_registry")
		local registry = require("ui.menu.menu_llm.prediction_lock_registry").new({
			state = state,
			keymap = keymap,
		})
		local startup = load_real_startup_owner(nil, {
			state = state,
			keymap = keymap,
			prediction_locks = registry,
			prediction_calls = calls,
		})
		local model = load_real_model_switch_owner({
			state = state,
			keymap = keymap,
			prediction_locks = registry,
			prediction_calls = calls,
		})
		fire_timer_delay(startup, 1)
		helpers.assert_true(model.switcher.switch_model("candidate"))
		return {
			state = state,
			registry = registry,
			startup = startup,
			model = model,
			calls = calls,
			get_runtime = function() return runtime end,
		}
	end

	for _, first in ipairs({ "startup", "model" }) do
		helpers.it("restores only after the last real owner when " .. first
			.. " completes first", function()
			local ctx = build_overlap()
			helpers.assert_eq(ctx.get_runtime(), false)
			if first == "startup" then
				ctx.startup.probes[1].on_ok()
				helpers.assert_eq(ctx.get_runtime(), false)
				ctx.model.get_probe().on_fail()
			else
				ctx.model.get_probe().on_fail()
				helpers.assert_eq(ctx.get_runtime(), false)
				ctx.startup.probes[1].on_ok()
			end
			helpers.assert_eq(ctx.get_runtime(), true)
			ctx.startup.probes[1].on_ok()
			ctx.model.get_probe().on_fail()
			helpers.assert_eq(ctx.get_runtime(), true)
		end)
	end

	helpers.it("keeps the gate disabled when preference turns off during overlap", function()
		local ctx = build_overlap()
		ctx.state.llm_enabled = false
		helpers.assert_true(ctx.registry.apply_preference(false))
		ctx.model.get_probe().on_fail()
		ctx.startup.probes[1].on_ok()
		helpers.assert_eq(ctx.get_runtime(), false)
	end)
end)

local function get_upvalue(fn, target)
	for index = 1, 80 do
		local name, value = debug.getupvalue(fn, index)
		if not name then return nil end
		if name == target then return value end
	end
	return nil
end

local function load_remote_native_http()
	local state = {
		cancel_mode = "true",
		cancel_handles = {},
		callbacks = {},
		tasks = {},
		get_calls = 0,
		post_calls = 0,
		sync_get = false,
	}
	local timer_stub = {
		secondsSinceEpoch = function() return 100 end,
		doAfter = function() error("HttpClient must use the exact scheduler adapter") end,
	}
	function timer_stub.new(_, callback)
		local running = false
		local native = { callback = callback }
		function native:start()
			running = true
			return self
		end
		function native:running() return running end
		function native:stop()
			running = false
			return self
		end
		return native
	end

	local function new_task()
		local task = {}
		function task:cancel()
			state.cancel_handles[#state.cancel_handles + 1] = self
			if state.cancel_mode == "throw" then error("native HTTP cancel exploded") end
			if state.cancel_mode == "false" then return false end
			if state.cancel_mode == "nil" then return nil end
			return true
		end
		state.tasks[#state.tasks + 1] = task
		return task
	end
	local http_stub = {
		encodeForQuery = function(value) return tostring(value) end,
		doAsyncRequest = function(_, method, _, _, callback, enable_redirect)
			helpers.assert_eq(enable_redirect, false,
				"credentialed Remote probes must disable native redirect following")
			if method == "GET" then
				state.get_calls = state.get_calls + 1
				state.callbacks[#state.callbacks + 1] = callback
				local task = new_task()
				if state.sync_get == true then callback(200, [[{"data":[]}]], {}) end
				return task
			end
			state.post_calls = state.post_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			return new_task()
		end,
		asyncGet = function(_, _, callback)
			state.get_calls = state.get_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			local task = new_task()
			if state.sync_get == true then callback(200, [[{"data":[]}]], {}) end
			return task
		end,
		asyncPost = function(_, _, _, callback)
			state.post_calls = state.post_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			return new_task()
		end,
	}
	reset_module("adapters.http_client")
	reset_module("adapters.timer_scheduler")
	helpers.load_with_stubs("adapters.http_client", {
		timer = timer_stub,
		http = http_stub,
	})
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return false end,
		get_pause_epoch = function() return 0 end,
	}
	reset_module("modules.llm.api_remote")
	local api = helpers.load_with_stubs("modules.llm.api_remote")
	api.PROVIDERS.fixture = {
		label = "Fixture",
		base_url = "https://fixture.invalid",
		default_model = "fixture-model",
		format = "openai",
	}
	api.set_entries({ {
		id = "entry-native",
		provider = "fixture",
		base_url = "https://fixture.invalid",
		token = "plain-token",
		model = "fixture-model",
	} })
	api.set_active_entry_id("entry-native")
	return api, state
end

helpers.describe("HS-012 real Remote HTTP pause ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates inference " .. mode
			.. " cancellation through prediction reset", function()
			local api, native = load_remote_native_http()
			local infer_client = get_upvalue(api.cancel_streaming, "_infer_client")
			helpers.assert_not_nil(infer_client)
			local deliveries = 0
			helpers.assert_true(infer_client.post(
				"https://fixture.invalid/infer", {}, "{}", function()
					deliveries = deliveries + 1
				end))
			helpers.assert_eq(native.post_calls, 1)
			local task = native.tasks[1]
			native.cancel_mode = mode
			local script_control = load_inventory_context({
				remote = api,
				keymap = {
					pause_processing = function() return true end,
					resume_processing = function() return true end,
					reset_predictions = api.cancel_streaming,
					reset_predictions_for_pause = api.cancel_streaming,
				},
			})
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused inference cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task,
				"prediction reset must retain the exact native inference task")

			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(native.cancel_handles[2], task,
				"pause retry must settle the same inference handle")
			native.callbacks[1](200, [[{"data":[]}]], {})
			helpers.assert_eq(deliveries, 0,
				"logical revocation must fence a queued native response")
			helpers.assert_true(script_control.resume_all())
			script_control.stop()
		end)

		helpers.it("accepts late inference terminal proof after " .. mode
			.. " cancellation", function()
			local api, native = load_remote_native_http()
			local infer_client = get_upvalue(api.cancel_streaming, "_infer_client")
			local deliveries = 0
			helpers.assert_true(infer_client.post(
				"https://fixture.invalid/infer", {}, "{}", function()
					deliveries = deliveries + 1
				end))
			local task = native.tasks[1]
			native.cancel_mode = mode
			local script_control = load_inventory_context({
				remote = api,
				keymap = {
					pause_processing = function() return true end,
					resume_processing = function() return true end,
					reset_predictions = api.cancel_streaming,
					reset_predictions_for_pause = api.cancel_streaming,
				},
			})
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused inference cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task)
			native.callbacks[1](200, "late", {})
			helpers.assert_eq(deliveries, 0)
			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all(),
				"natural terminal proof must settle the retained capability")
			helpers.assert_eq(#native.cancel_handles, 1,
				"a naturally settled task needs no second native cancellation")
			helpers.assert_eq(native.post_calls, 1,
				"pause retry cannot dispatch a sibling inference request")
			helpers.assert_true(script_control.resume_all())
			script_control.stop()
		end)

		helpers.it("joins availability " .. mode
			.. " cancellation without restoring stale work", function()
			local api, native = load_remote_native_http()
			local available, missing = 0, 0
			native.sync_get = true
			helpers.assert_true(api.check_availability(nil,
				function() available = available + 1 end,
				function() missing = missing + 1 end))
			helpers.assert_eq(available, 1,
				"positive control must exercise synchronous native completion")
			native.callbacks[1](200, "{}", {})
			helpers.assert_eq(available, 1,
				"duplicate synchronous completion must be one-shot")

			native.sync_get = false
			helpers.assert_true(api.check_availability(nil,
				function() available = available + 1 end,
				function() missing = missing + 1 end))
			local task = native.tasks[2]
			native.cancel_mode = mode
			local script_control = load_inventory_context({ remote = api })
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused availability cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task)
			native.callbacks[2](200, [[{"data":[]}]], {})
			helpers.assert_eq(available, 1)
			helpers.assert_eq(missing, 0)

			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(native.cancel_handles[#native.cancel_handles], task,
				"availability retry must settle the same native task")
			native.callbacks[2](503, "late", {})
			helpers.assert_eq(available, 1)
			helpers.assert_eq(missing, 0,
				"global pause never restores or publishes a stale availability check")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(native.get_calls, 2,
				"resume must join cleanup debt without restoring an availability request")
			script_control.stop()
		end)
	end
end)

local function load_commit_staged_backend(kind, options)
	options = options or {}
	local timers = {}
	local timer_after_calls = 0
	local timer_after_modes = options.timer_after_modes or {}
	local timer_cancel_mode = "true"
	local timer_cancel_handles = {}
	local cancel_timer
	local timer_scheduler = {
		now = function() return 100 end,
		after = function(delay, callback)
			timer_after_calls = timer_after_calls + 1
			local mode = timer_after_modes[timer_after_calls] or "true"
			if mode == "throw" then error("resume-stage acquisition exploded") end
			if mode == "nil" then return nil, nil end
			if mode == "false" then return { timer = nil, committed = false }, false end
			local committed = mode ~= "partial"
			local handle = { timer = {}, committed = committed, observers = {} }
			local entry = { delay = delay, handle = handle }
			entry.callback = function()
				if handle.timer == nil then return end
				if handle.committed ~= true then
					pcall(cancel_timer, handle)
					return
				end
				handle.committed = false
				pcall(cancel_timer, handle)
				callback()
			end
			timers[#timers + 1] = entry
			return handle, committed
		end,
		cancel = function(handle)
			if type(handle) ~= "table" or handle.timer == nil then return true end
			handle.committed = false
			timer_cancel_handles[#timer_cancel_handles + 1] = handle
			if timer_cancel_mode == "throw" then error("resume-stage cancel exploded") end
			if timer_cancel_mode == "false" then return false end
			if timer_cancel_mode == "nil" then return nil end
			handle.timer = nil
			local observers = handle.observers or {}
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
		onSettled = function(handle, observer)
			if type(handle) ~= "table" or type(observer) ~= "function" then return false end
			if handle.timer == nil then observer(); return true end
			handle.observers = handle.observers or {}
			handle.observers[#handle.observers + 1] = observer
			return true
		end,
	}
	cancel_timer = timer_scheduler.cancel
	package.loaded["adapters.timer_scheduler"] = timer_scheduler
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return false end,
		get_pause_epoch = function() return 0 end,
	}
	local notifications = 0
	package.loaded["infra.notifications"] = {
		notify = function() notifications = notifications + 1 end,
	}
	local decrypt_callbacks = {}
	local decrypt_calls = 0
	if options.encrypted == true then
		package.loaded["modules.llm.api_token_crypto"] = {
			is_encrypted = function(value)
				return type(value) == "string" and value:sub(1, 9) == "keychain:"
			end,
			decrypt_async = function(_, callback)
				decrypt_calls = decrypt_calls + 1
				decrypt_callbacks[#decrypt_callbacks + 1] = callback
				return { cancel = function() return true end }
			end,
		}
	end
	local module_name = kind == "remote"
		and "modules.llm.api_remote" or "modules.llm.api_ollama"
	reset_module(module_name)
	local api = helpers.load_with_stubs(module_name)
	if kind == "remote" then
		api.PROVIDERS.fixture = {
			label = "Fixture",
			base_url = "https://fixture.invalid",
			default_model = "fixture-model",
			format = "openai",
		}
		api.set_entries({ {
			id = "entry-a",
			provider = "fixture",
			base_url = "https://fixture.invalid",
			token = options.encrypted == true and "keychain:fixture" or "plain-token",
			model = "fixture-model",
		} })
		api.set_active_entry_id("entry-a")
	end
	local client = get_upvalue(api.warmup, "_warmup_client")
	helpers.assert_not_nil(client)
	local requests = 0
	local request_modes = options.request_modes or {}
	local client_cleanup_debt = false
	local client_settlement_observers = {}
	local initial_callback = nil
	client.cancel = function() return true end
	client.onSettled = function(observer)
		if client_cleanup_debt ~= true then observer(); return true end
		client_settlement_observers[#client_settlement_observers + 1] = observer
		return true
	end
	local function capture_request(on_done)
		requests = requests + 1
		local mode = request_modes[requests] or "true"
		if mode ~= "true" and options.request_settlement_debt == true then
			client_cleanup_debt = true
		end
		if mode == "sync_false" then
			on_done(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
			return false
		end
		if mode == "throw" then error("warmup request acquisition exploded") end
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if requests == 1 then
			initial_callback = on_done
		else
			on_done(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
		end
		return true
	end
	if kind == "remote" then
		client.get = function(_, _, on_done) return capture_request(on_done) end
	else
		client.post = function(_, _, _, on_done) return capture_request(on_done) end
	end
	helpers.assert_true(api.warmup("fixture-model", nil))
	if options.encrypted == true then
		helpers.assert_not_nil(decrypt_callbacks[1])
		decrypt_callbacks[1](true, "plain-token", nil)
	end
	helpers.assert_not_nil(initial_callback)
	return {
		api = api,
		timers = timers,
		get_requests = function() return requests end,
		get_notifications = function() return notifications end,
		get_timer_cancel_handles = function() return timer_cancel_handles end,
		get_timer_after_calls = function() return timer_after_calls end,
		get_decrypt_calls = function() return decrypt_calls end,
		resolve_decrypt = function(index)
			decrypt_callbacks[index](true, "plain-token", nil)
		end,
		set_timer_cancel_mode = function(mode) timer_cancel_mode = mode end,
		settle_client = function()
			client_cleanup_debt = false
			local observers = client_settlement_observers
			client_settlement_observers = {}
			for _, observer in ipairs(observers) do observer() end
		end,
		fire_initial = function()
			initial_callback(kind == "remote"
				and { ok = true, status = 200, body = [[{"data":[]}]] }
				or { status = 200 })
		end,
	}
end

helpers.describe("HS-012 Remote/Ollama post-commit warmup staging", function()
	for _, kind in ipairs({ "remote", "ollama" }) do
		helpers.it(kind .. " explicit disable consumes paused restore intent", function()
			local backend = load_commit_staged_backend(kind)
			helpers.assert_true(backend.api.pause_warmup())
			helpers.assert_true(backend.api.stop_warmup(),
				"the explicit disable boundary must settle the paused owner")
			helpers.assert_true(backend.api.resume_warmup())
			helpers.assert_eq(#backend.timers, 0)
			helpers.assert_eq(backend.get_requests(), 1,
				"resume may not resurrect a warmup explicitly disabled during PAUSED")
			backend.fire_initial()
			helpers.assert_eq(backend.api.is_ready(), false)
		end)

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " recovers a clean " .. mode
				.. " request and retry-stage refusal", function()
				local backend = load_commit_staged_backend(kind, {
					timer_after_modes = { "true", mode, mode },
					request_modes = { "true", mode, "true" },
				})
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(#backend.timers, 1)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(#backend.timers, 1,
					"readiness polling must not replace a committed resume stage")
				helpers.assert_eq(backend.get_timer_after_calls(), 1)
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_timer_after_calls(), 3,
					"post-commit recovery must make only two bounded staging attempts")
				helpers.assert_eq(backend.get_requests(), 3,
					"clean staging refusal must fall back to one exact direct request")
				helpers.assert_true(backend.api.is_ready(),
					"the bounded direct fallback must restore readiness")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 3,
					"duplicate stage delivery cannot repeat the fallback")
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		helpers.it(kind .. " publishes one successor after synchronous stage settlement", function()
			local backend = load_commit_staged_backend(kind, {
				timer_after_modes = { "true", "partial", "true", "true" },
				request_modes = { "true", "false", "true" },
			})
			local script_control = load_inventory_context({
				remote = kind == "remote" and backend.api or nil,
				ollama = kind == "ollama" and backend.api or nil,
			})
			helpers.assert_true(script_control.pause_all())
			backend.fire_initial()
			helpers.assert_true(script_control.resume_all())
			backend.timers[1].callback()
			helpers.assert_eq(backend.get_timer_after_calls(), 2)
			helpers.assert_eq(#backend.timers, 2,
				"the refused retry stage must retain its exact live handle")

			helpers.assert_eq(backend.api.is_ready(), false)
			helpers.assert_eq(backend.get_timer_after_calls(), 3,
				"synchronous onSettled reentrance may publish only one successor")
			helpers.assert_eq(#backend.timers, 3)
			helpers.assert_eq(backend.api.is_ready(), false)
			helpers.assert_eq(backend.get_timer_after_calls(), 3,
				"the committed successor must be idempotent under polling")
			backend.timers[3].callback()
			helpers.assert_eq(backend.get_requests(), 3)
			helpers.assert_true(backend.api.is_ready())
			helpers.assert_true(backend.api.stop_warmup())
			script_control.stop()
		end)

		for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " joins a due resume stage after terminal stop "
				.. stop_mode, function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				backend.set_timer_cancel_mode(stop_mode)
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"a due stage cannot dispatch while its native timer remains live")
				helpers.assert_eq(backend.get_timer_after_calls(), 1)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"polling cannot acquire over terminal timer cleanup debt")

				backend.set_timer_cancel_mode("true")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_timer_after_calls(), 2,
					"settlement may publish one replacement stage")
				helpers.assert_eq(backend.get_requests(), 1)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.is_ready())
				backend.timers[1].callback()
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		helpers.it(kind .. " discards a synchronous response when dispatch refuses", function()
			local backend = load_commit_staged_backend(kind, {
				request_modes = { "true", "sync_false", "true" },
			})
			local script_control = load_inventory_context({
				remote = kind == "remote" and backend.api or nil,
				ollama = kind == "ollama" and backend.api or nil,
			})
			helpers.assert_true(script_control.pause_all())
			backend.fire_initial()
			helpers.assert_true(script_control.resume_all())
			backend.timers[1].callback()
			helpers.assert_eq(backend.api.is_ready(), false,
				"a response delivered before false dispatch cannot publish readiness")
			helpers.assert_eq(#backend.timers, 2,
				"the refused dispatch must retain intent through one retry stage")
			backend.timers[2].callback()
			helpers.assert_true(backend.api.is_ready())
			helpers.assert_eq(backend.get_requests(), 3)
			if kind == "ollama" then
				helpers.assert_eq(backend.get_notifications(), 1,
					"only the committed response may notify readiness")
			end
			helpers.assert_true(backend.api.stop_warmup())
			script_control.stop()
		end)

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " waits for internal HTTP " .. mode
				.. " debt before staging a successor", function()
				local backend = load_commit_staged_backend(kind, {
					request_modes = { "true", mode, "true" },
					request_settlement_debt = true,
				})
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_true(script_control.resume_all())
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"an internal HTTP owner must settle before any retry timer exists")
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.api.is_ready(), false)
				helpers.assert_eq(backend.get_timer_after_calls(), 1,
					"readiness polling cannot bypass the retained HTTP owner")

				backend.settle_client()
				helpers.assert_eq(backend.get_timer_after_calls(), 2,
					"exact client settlement may acquire one retry stage")
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 3)
				helpers.assert_true(backend.api.is_ready())
				backend.settle_client()
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 3)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		if kind == "remote" then
			for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("remote starts no decrypt while due stage stop is "
					.. stop_mode, function()
					local backend = load_commit_staged_backend("remote", { encrypted = true })
					local script_control = load_inventory_context({ remote = backend.api })
					helpers.assert_true(script_control.pause_all())
					backend.fire_initial()
					helpers.assert_true(script_control.resume_all())
					backend.set_timer_cancel_mode(stop_mode)
					backend.timers[1].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 1,
						"terminal timer debt must fence the resumed Keychain operation")
					helpers.assert_eq(backend.get_requests(), 1)
					backend.set_timer_cancel_mode("true")
					backend.timers[1].callback()
					helpers.assert_eq(#backend.timers, 2)
					backend.timers[2].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2)
					helpers.assert_eq(backend.get_requests(), 1)
					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 2)
					helpers.assert_true(backend.api.is_ready())
					helpers.assert_true(backend.api.stop_warmup())
					script_control.stop()
				end)
			end

			for _, mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("remote retains encrypted resume intent after late GET "
					.. mode, function()
					local backend = load_commit_staged_backend("remote", {
						encrypted = true,
						request_modes = { "true", mode, "true" },
						request_settlement_debt = true,
					})
					local script_control = load_inventory_context({ remote = backend.api })
					helpers.assert_true(script_control.pause_all())
					backend.fire_initial()
					helpers.assert_true(script_control.resume_all())
					helpers.assert_eq(#backend.timers, 1)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(#backend.timers, 1,
						"readiness polling cannot replace the committed stage")

					backend.timers[1].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"stage delivery must own one resumed Keychain operation")
					helpers.assert_eq(backend.get_requests(), 1)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(backend.api.is_ready(), false)
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"polling cannot replace the asynchronous resolver lease")

					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 2)
					helpers.assert_eq(backend.get_timer_after_calls(), 1,
						"late GET debt must block every retry stage")
					backend.settle_client()
					helpers.assert_eq(#backend.timers, 2)
					backend.timers[2].callback()
					helpers.assert_eq(backend.get_decrypt_calls(), 2,
						"retry must reuse the already-resolved token cache without a sibling Keychain task")
					helpers.assert_eq(backend.get_requests(), 3)
					helpers.assert_true(backend.api.is_ready())
					backend.resolve_decrypt(2)
					helpers.assert_eq(backend.get_requests(), 3,
						"duplicate stale decrypt completion cannot launch a sibling GET")
					helpers.assert_true(backend.api.stop_warmup())
					script_control.stop()
				end)
			end
		end

		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " stays inert when a later resume owner returns " .. mode, function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
					fail_owner = "wpm_menubar",
					fail_mode = mode,
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				backend.fire_initial()
				helpers.assert_eq(backend.api.is_ready(), false,
					"the pre-pause terminal must be generation-fenced")

				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(#backend.timers, 1,
					"the backend must stage exactly one post-commit owner")
				backend.timers[1].callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"a rollback-retained timer callback may not dispatch under PAUSED")
				helpers.assert_eq(backend.get_notifications(), 0)

				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.is_ready())
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2,
					"duplicate staged delivery must remain one-shot")
				if kind == "ollama" then
					helpers.assert_eq(backend.get_notifications(), 1)
				end
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end

		for _, cancel_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it(kind .. " retains the same resume stage after " .. cancel_mode
				.. " rollback cancellation", function()
				local backend = load_commit_staged_backend(kind)
				local script_control = load_inventory_context({
					remote = kind == "remote" and backend.api or nil,
					ollama = kind == "ollama" and backend.api or nil,
					fail_owner = "wpm_menubar",
					fail_mode = "false",
					fail_direction = "resume",
				})
				helpers.assert_true(script_control.pause_all())
				backend.set_timer_cancel_mode(cancel_mode)
				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(#backend.timers, 1)
				local retained_stage = backend.timers[1]
				local cancel_handles = backend.get_timer_cancel_handles()
				helpers.assert_eq(cancel_handles[1], retained_stage.handle,
					"rollback must retain the exact post-commit timer capability")

				retained_stage.callback()
				helpers.assert_eq(backend.get_requests(), 1,
					"retained callback remains inert while the global transaction is PAUSED")
				helpers.assert_eq(cancel_handles[#cancel_handles], retained_stage.handle,
					"callback retry must target the same unsettled handle")

				backend.set_timer_cancel_mode("true")
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(cancel_handles[#cancel_handles], retained_stage.handle,
					"resume retry must settle the retained handle before acquiring a successor")
				helpers.assert_eq(#backend.timers, 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				backend.timers[2].callback()
				helpers.assert_eq(backend.get_requests(), 2)
				helpers.assert_true(backend.api.stop_warmup())
				script_control.stop()
			end)
		end
	end
end)

helpers.describe("HS-012 real Remote warmup generation", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins shared prewarm Keychain ownership after " .. mode, function()
			local decrypt_callbacks = {}
			local decrypt_calls = 0
			local cancel_calls = 0
			local operations = {}
			local cancelled_operations = {}
			local cancel_mode = mode
			package.loaded["modules.llm.api_token_crypto"] = {
				is_encrypted = function() return true end,
				decrypt_async = function(_, callback)
					decrypt_calls = decrypt_calls + 1
					decrypt_callbacks[#decrypt_callbacks + 1] = callback
					local operation = {}
					function operation.cancel()
						cancel_calls = cancel_calls + 1
						cancelled_operations[#cancelled_operations + 1] = operation
						if cancel_mode == "throw" then error("Keychain cancel exploded") end
						if cancel_mode == "false" then return false end
						if cancel_mode == "nil" then return nil end
						return true
					end
					operations[#operations + 1] = operation
					return operation
				end,
			}
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_remote")
			local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")
			ApiRemote.PROVIDERS.fixture = {
				label = "Fixture",
				base_url = "https://fixture.invalid",
				default_model = "fixture-model",
				format = "openai",
			}
			ApiRemote.set_entries({ {
				id = "entry-keychain",
				provider = "fixture",
				base_url = "https://fixture.invalid",
				token = "keychain:fixture",
				model = "fixture-model",
			} })
			ApiRemote.set_active_entry_id("entry-keychain")
			local client = get_upvalue(ApiRemote.warmup, "_warmup_client")
			local get_calls = 0
			client.get = function()
				get_calls = get_calls + 1
				return true
			end
			client.cancel = function() return true end

			ApiRemote.prewarm_active_entry_decrypt()
			helpers.assert_true(ApiRemote.warmup("fixture-model"))
			helpers.assert_not_nil(decrypt_callbacks[1])
			helpers.assert_eq(decrypt_calls, 1)
			helpers.assert_eq(ApiRemote.pause_warmup(), false,
				"the shared prewarm operation must reject non-exact cancellation")
			helpers.assert_eq(cancel_calls, 1)
			cancel_mode = "true"
			helpers.assert_true(ApiRemote.pause_warmup())
			helpers.assert_eq(cancel_calls, 2,
				"the exact same Keychain operation must remain retryable")
			helpers.assert_eq(cancelled_operations[1], operations[1])
			helpers.assert_eq(cancelled_operations[2], operations[1])
			decrypt_callbacks[1](true, "plain-token", nil)
			helpers.assert_eq(get_calls, 0,
				"a late shared resolver terminal must remain inert after pause")
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(decrypt_calls, 2,
				"the exact encrypted warmup intent must survive cancellation debt")
			helpers.assert_true(operations[2] ~= operations[1],
				"restoration must acquire one fresh Keychain operation after settlement")
			helpers.assert_eq(get_calls, 0)
			helpers.assert_eq(ApiRemote.is_ready(), false)
			helpers.assert_eq(ApiRemote.is_ready(), false)
			helpers.assert_eq(decrypt_calls, 2,
				"readiness polling cannot replace an owned resumed Keychain lease")
			decrypt_callbacks[2](true, "plain-token", nil)
			helpers.assert_eq(get_calls, 1)
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(decrypt_calls, 2)
			helpers.assert_eq(get_calls, 1,
				"duplicate resume may not acquire a sibling warmup")
			helpers.assert_true(ApiRemote.stop_warmup())
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps and restores Remote intent after " .. mode .. " cancellation", function()
			-- The preceding encrypted-owner matrix installs an always-encrypted
			-- TokenCrypto double. Restore the real prefix contract so this plain-token
			-- positive control cannot accidentally wait on a phantom Keychain task.
			package.loaded["modules.llm.api_token_crypto"] = {
				is_encrypted = function(value)
					return type(value) == "string" and value:sub(1, 9) == "keychain:"
				end,
				decrypt_async = function()
					error("plain-token warmup must not dispatch Keychain decryption")
				end,
			}
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_remote")
			local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")
			ApiRemote.PROVIDERS.fixture = {
				label = "Fixture",
				base_url = "https://fixture.invalid",
				default_model = "fixture-model",
				format = "openai",
			}
			ApiRemote.set_entries({ {
				id = "entry-a",
				provider = "fixture",
				base_url = "https://fixture.invalid",
				token = "plain-token",
				model = "fixture-model",
			} })
			ApiRemote.set_active_entry_id("entry-a")
			local client = get_upvalue(ApiRemote.warmup, "_warmup_client")
			helpers.assert_not_nil(client)
			local callback = nil
			local get_calls = 0
			local original_get = client.get
			local original_cancel = client.cancel
			client.get = function(_, _, on_done)
				get_calls = get_calls + 1
				callback = on_done
				return true
			end
			local cancel_mode = mode
			client.cancel = function()
				if cancel_mode == "false" then return false end
				if cancel_mode == "nil" then return nil end
				if cancel_mode == "throw" then error("remote cancellation exploded") end
				return true
			end

			ApiRemote.warmup()
			helpers.assert_eq(type(callback), "function",
				"positive control must dispatch the real Remote warmup callback")
			callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), true,
				"positive control proves the production callback can publish readiness")
			ApiRemote.warmup()
			local late_callback = callback
			helpers.assert_eq(ApiRemote.pause_warmup(), false,
				"non-exact HTTP settlement must reject the pause owner")
			late_callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), false,
				"the generation fence must beat a refused native cancellation")
			helpers.assert_eq(ApiRemote.resume_warmup(), false,
				"rollback may not consume intent over the same cancellation debt")
			cancel_mode = "true"
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(ApiRemote.is_ready(), false,
				"readiness stays fenced until the resumed request completes")
			helpers.assert_eq(get_calls, 3)
			callback({ ok = true, status = 200, body = [[{"data":[]}]] })
			helpers.assert_eq(ApiRemote.is_ready(), true)
			helpers.assert_true(ApiRemote.resume_warmup())
			helpers.assert_eq(get_calls, 3,
				"duplicate resume must not replay a settled Remote warmup")
			client.get = original_get
			client.cancel = original_cancel
		end)
	end
end)

helpers.describe("HS-012 real Ollama warmup generation", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps and restores Ollama intent after " .. mode .. " cancellation", function()
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return false end,
				get_pause_epoch = function() return 0 end,
			}
			reset_module("modules.llm.api_ollama")
			local ApiOllama = helpers.load_with_stubs("modules.llm.api_ollama")
			local client = get_upvalue(ApiOllama.warmup, "_warmup_client")
			helpers.assert_not_nil(client)
			local callback = nil
			local post_calls = 0
			local cancel_mode = mode
			local original_post = client.post
			local original_cancel = client.cancel
			client.post = function(_, _, _, on_done)
				post_calls = post_calls + 1
				callback = on_done
				return true
			end
			client.cancel = function()
				if cancel_mode == "false" then return false end
				if cancel_mode == "nil" then return nil end
				if cancel_mode == "throw" then error("Ollama cancellation exploded") end
				return true
			end

			helpers.assert_true(ApiOllama.warmup("fixture-model"))
			callback({ status = 200 })
			helpers.assert_true(ApiOllama.is_ready())
			ApiOllama.reset_ready()
			helpers.assert_true(ApiOllama.warmup("fixture-model"))
			local late_callback = callback
			helpers.assert_eq(ApiOllama.pause_warmup(), false)
			late_callback({ status = 200 })
			helpers.assert_eq(ApiOllama.is_ready(), false)
			helpers.assert_eq(ApiOllama.resume_warmup(), false)
			cancel_mode = "true"
			helpers.assert_true(ApiOllama.resume_warmup())
			helpers.assert_eq(ApiOllama.is_ready(), false)
			helpers.assert_eq(post_calls, 3)
			callback({ status = 200 })
			helpers.assert_true(ApiOllama.is_ready())
			helpers.assert_true(ApiOllama.resume_warmup())
			helpers.assert_eq(post_calls, 3)
			client.post = original_post
			client.cancel = original_cancel
		end)
	end
end)

return true
