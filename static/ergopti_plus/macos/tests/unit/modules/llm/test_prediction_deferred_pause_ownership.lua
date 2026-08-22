--- tests/unit/modules/llm/test_prediction_deferred_pause_ownership.lua

--- ==============================================================================
--- MODULE: Prediction Timer Pause Ownership Regressions
--- DESCRIPTION:
--- Drives the real prediction engine and TimerScheduler through inactivity,
--- chain, and dismissal callbacks crossed by a global-pause reset. A naturally
--- settled native timer remains a logical owner until its business callback
--- returns; pause must reject that in-stack predecessor and no fenced callback
--- may dispatch, replay, or create a sibling continuation.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a fresh production prediction engine with faithful native timers.
--- @return table fixture Observable engine, timers, and telemetry counters.
local function load_fixture()
	helpers.load_with_stubs("infra.logger")
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.llm.prediction_engine"] = nil

	local fixture = {
		cancel_mode = nil,
		dismissed = 0,
		now = 100,
		rate_limit = 0,
		timers = {},
		profile_pause_calls = 0,
		profile_pause_result = true,
		pause_on_start = false,
		pause_in_callback = false,
		start_mode = nil,
	}
	_G.hs.timer.secondsSinceEpoch = function() return fixture.now end
	_G.hs.timer.new = function(delay, callback)
		local candidate = {
			callback = callback,
			delay = delay,
			live = false,
			starts = 0,
			stops = 0,
		}
		function candidate:start()
			self.starts = self.starts + 1
			self.live = true
			if fixture.pause_on_start == true then
				fixture.pause_on_start = false
				fixture.start_pause_result = fixture.engine.reset({ suppress_telemetry = true })
			end
			local mode = fixture.start_mode
			fixture.start_mode = nil
			if mode == "throw" then error("native prediction timer start failed") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			return self
		end
		function candidate:stop()
			self.stops = self.stops + 1
			if fixture.cancel_mode == "throw" then
				error("native prediction telemetry stop failed")
			end
			if fixture.cancel_mode == "false" then return false end
			if fixture.cancel_mode == "nil" then return nil end
			self.live = false
			return self
		end
		function candidate:running()
			local reenter = fixture.reenter_on_running
			if type(reenter) == "function" then
				fixture.reenter_on_running = nil
				fixture.running_reentry_result = reenter()
			end
			return self.live
		end
		fixture.timers[#fixture.timers + 1] = candidate
		return candidate
	end

	local defaults = {
		llm_enabled = false,
		llm_temperature = 0.1,
		llm_context_length = 4000,
		llm_min_words = 1,
		llm_max_words = 0,
		llm_num_predictions = 1,
		llm_pred_indent = 0,
		llm_val_modifiers = { "alt" },
		llm_nav_modifiers = { "ctrl" },
		llm_show_info_bar = true,
		llm_sequential_mode = false,
		llm_debounce = 0.1,
		llm_auto_raise_temp = false,
		llm_streaming = false,
		llm_streaming_multi = false,
		llm_instant_on_word_end = false,
		llm_disable_url_bars = false,
		llm_disable_password_fields = true,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = defaults,
		cancel_streaming = function() return true end,
		fetch_llm_prediction = function(...)
			local on_success = select(7, ...)
			on_success({ { to_type = " completion", deletes = 0 } }, 1, true, false)
		end,
		get_active_profile = function() return { label = "Fixture" } end,
		get_backend = function() return "mlx" end,
		get_current_model = function() return "fixture-model" end,
		is_backend_ready = function() return true end,
		pause_deferred_profile_warmup = function()
			fixture.profile_pause_calls = fixture.profile_pause_calls + 1
			return fixture.profile_pause_result
		end,
		set_runtime_llm_enabled = function() return true end,
	}
	fixture.core = package.loaded["modules.llm"]
	package.loaded["modules.llm.warmup_controller"] = {
		init = function() return true end,
		schedule_warmup_with_retry = function() return true end,
		start = function() return true end,
		stop = function() return true end,
	}
	package.loaded["modules.llm.api_mlx"] = {
		resume_warmup = function() return true end,
		stop_warmup = function() return true end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		stop_warmup = function() return true end,
	}
	package.loaded["modules.llm.api_remote"] = {
		stop_warmup = function() return true end,
	}
	package.loaded["modules.llm.prompt_builder"] = {
		build = function()
			return {
				context_buffer = "hello wor",
				max_tokens = 16,
				num_preds = 1,
				req_temperature = 0.1,
				tail = "wor",
			}, nil, "fixture-signature"
		end,
	}
	package.loaded["modules.llm.streaming_handler"] = {
		arm_watchdog = function() return true end,
		build_callbacks = function(config)
			local function success(predictions)
				config.pending_predictions_ref.value = predictions
				config.predictions_visible_ref.value = true
				return true
			end
			return nil, success, function() return true end
		end,
		init = function() return true end,
		reset_failure_count = function() return true end,
		stop_watchdog = function() return true end,
	}
	fixture.streaming_handler = package.loaded["modules.llm.streaming_handler"]
	package.loaded["modules.llm.app_filter"] = {
		is_blocked = function() return false end,
	}
	package.loaded["modules.llm.api_common"] = {
		get_rate_limit_min_interval_s = function() return fixture.rate_limit end,
	}
	package.loaded["infra.timings"] = {
		sec = function() return 0.1 end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		t = function(key) return key end,
	}
	package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
	package.loaded["ui.tooltip"] = {
		get_current_index = function() return nil end,
		hide = function() return true end,
		hide_forced = function() return true end,
		hide_forced_silent = function() return true end,
		mark_chain_complete = function() return true end,
		navigate = function() return true end,
		reset_llm_timer = function() return true end,
		set_chain_start = function() return true end,
		set_enter_validates = function() return true end,
		set_llm_timeout = function() return true end,
		set_navigate_callback = function() return true end,
		show_loading = function() return true end,
		show_predictions = function() return true end,
		tint = function() return nil end,
	}
	fixture.tooltip = package.loaded["ui.tooltip"]
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm_dismissed = function()
			if fixture.pause_in_callback == true then
				fixture.pause_in_callback = false
				fixture.callback_pause_result = fixture.engine.reset({
					suppress_telemetry = true,
				})
			end
			fixture.dismissed = fixture.dismissed + 1
			return true
		end,
	}

	fixture.engine = require("modules.llm.prediction_engine")
	helpers.assert_true(fixture.engine.set_llm_enabled(true))
	fixture.state = {
		buffer = "hello wor",
		llm_buffer = "hello wor",
		mappings = {},
		DELAYS = { llm_prediction = 0 },
		suppress_rescan_keep_buffer = function() return true end,
	}
	helpers.assert_true(fixture.engine.init(fixture.state))
	return fixture
end





-- ===============================================================
-- ===============================================================
-- ======= 1/ Deferred Telemetry Pause Ownership =================
-- ===============================================================
-- ===============================================================

helpers.describe("prediction engine: deferred telemetry pause ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and fences dismissal telemetry after " .. mode
			.. " cancellation", function()
			local fixture = load_fixture()
			fixture.engine.perform_check(true)
			helpers.assert_true(fixture.engine.is_visible(),
				"positive control must publish visible predictions")
			helpers.assert_true(fixture.engine.reset(),
				"ordinary reset must defer its user-dismissal telemetry")
			helpers.assert_eq(fixture.dismissed, 0)
			local predecessor = fixture.timers[1]
			helpers.assert_true(predecessor.live)

			fixture.cancel_mode = mode
			helpers.assert_eq(fixture.engine.reset({ suppress_telemetry = true }), false,
				"global PAUSE reset must reject unsettled predecessor telemetry")
			helpers.assert_eq(fixture.profile_pause_calls, 1,
				"the real prediction reset must join deferred profile warmup too")
			helpers.assert_true(predecessor.live)
			helpers.assert_eq(predecessor.stops, 1)
			predecessor.callback()
			helpers.assert_eq(predecessor.stops, 2)
			helpers.assert_eq(fixture.dismissed, 0,
				"late native delivery must be business-inert after the pause fence")

			fixture.cancel_mode = nil
			helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }),
				"same-state retry must settle the exact predecessor")
			helpers.assert_eq(fixture.profile_pause_calls, 2)
			helpers.assert_eq(predecessor.stops, 3)
			helpers.assert_eq(predecessor.live, false)
			helpers.assert_eq(#fixture.timers, 1,
				"pause cleanup is one-way and must not arm replacement telemetry")
			predecessor.callback()
			predecessor.callback()
			helpers.assert_eq(fixture.dismissed, 0,
				"duplicates remain inert after exact native settlement")
		end)
	end

	helpers.it("aggregates a deferred profile-warmup cleanup refusal", function()
		local fixture = load_fixture()
		fixture.profile_pause_result = false
		helpers.assert_eq(fixture.engine.reset({ suppress_telemetry = true }), false)
		helpers.assert_eq(fixture.profile_pause_calls, 1,
			"removing the ScriptControl-to-core warmup join must make this regression red")
	end)

	helpers.it("publishes the telemetry owner before native start re-enters PAUSE", function()
		local fixture = load_fixture()
		fixture.engine.perform_check(true)
		fixture.pause_on_start = true
		helpers.assert_eq(fixture.engine.reset(), false,
			"a start acquisition revoked by nested PAUSE cannot be reported committed")

		helpers.assert_eq(fixture.start_pause_result, false,
			"PAUSE cannot settle while the telemetry acquisition is still on stack")
		helpers.assert_eq(fixture.dismissed, 0)
		helpers.assert_eq(#fixture.timers, 1)
		helpers.assert_eq(fixture.timers[1].live, false,
			"the refused acquisition must compensate its exact native handle")
		fixture.timers[1].callback()
		fixture.timers[1].callback()
		helpers.assert_eq(fixture.dismissed, 0,
			"the compensated candidate can never publish telemetry")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reports telemetry start and rollback " .. mode
			.. " debt from ordinary reset", function()
			local fixture = load_fixture()
			fixture.engine.perform_check(true)
			helpers.assert_true(fixture.engine.is_visible())
			fixture.start_mode = mode
			fixture.cancel_mode = mode

			helpers.assert_eq(fixture.engine.reset(), false,
				"ordinary reset must expose its retained native telemetry debt")
			helpers.assert_eq(#fixture.timers, 1)
			local exact_timer = fixture.timers[1]
			helpers.assert_true(exact_timer.live,
				"a mutating start refusal with failed rollback must stay exactly owned")
			helpers.assert_true(exact_timer.stops >= 1,
				"the production rollback path must signal the acquired timer")

			exact_timer.callback()
			helpers.assert_eq(fixture.dismissed, 0,
				"a refused acquisition can never publish dismissal telemetry")
			fixture.cancel_mode = nil
			helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }),
				"same-state PAUSE retry must settle the retained exact timer")
			helpers.assert_eq(exact_timer.live, false)
			helpers.assert_eq(#fixture.timers, 1,
				"cleanup retry must not create a telemetry sibling")
			exact_timer.callback()
			exact_timer.callback()
			helpers.assert_eq(fixture.dismissed, 0)
		end)
	end

	helpers.it("keeps PAUSE pending until the telemetry callback returns", function()
		local fixture = load_fixture()
		fixture.engine.perform_check(true)
		helpers.assert_true(fixture.engine.reset())
		fixture.pause_in_callback = true
		fixture.timers[1].callback()

		helpers.assert_eq(fixture.callback_pause_result, false,
			"the settled timer remains a logical owner while its file write is running")
		helpers.assert_eq(fixture.dismissed, 1,
			"the failed nested PAUSE leaves the already-authorized callback ACTIVE")
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }),
			"a retry after callback return must observe exact settlement")
	end)

	helpers.it("preserves telemetry scheduled reentrantly during native settlement", function()
		local fixture = load_fixture()
		fixture.engine.perform_check(true)
		helpers.assert_true(fixture.engine.reset())
		fixture.engine.perform_check(true)
		fixture.reenter_on_running = function()
			return fixture.engine.reset()
		end

		helpers.assert_eq(fixture.engine.reset({ suppress_telemetry = true }), false,
			"the outer PAUSE must refuse a nested telemetry successor")
		helpers.assert_true(fixture.running_reentry_result)
		helpers.assert_eq(#fixture.timers, 2)
		helpers.assert_eq(fixture.timers[1].live, false)
		helpers.assert_true(fixture.timers[2].live)
		helpers.assert_eq(fixture.dismissed, 0)

		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
		helpers.assert_eq(fixture.timers[2].live, false)
		fixture.timers[1].callback()
		fixture.timers[2].callback()
		helpers.assert_eq(fixture.dismissed, 0)
	end)
end)





-- ================================================
-- ================================================
-- ======= 2/ Prediction Callback Ownership =======
-- ================================================
-- ================================================

--- Reads one named upvalue from a production function.
--- @param fn function Function carrying module state.
--- @param target string Upvalue name.
--- @return any value Current upvalue value.
local function read_upvalue(fn, target)
	for index = 1, 80 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target then return value end
	end
	return nil
end


helpers.describe("prediction engine: settled timer callback ownership", function()
	for _, boundary in ipairs({ "get_current_model", "show_loading", "fetch" }) do
		helpers.it("retains the inactivity owner through reentrant PAUSE in "
			.. boundary, function()
			local fixture = load_fixture()
			local observations = {
				fetch = 0,
				loading = 0,
				model = 0,
				pause = 0,
				pause_result = nil,
			}

			local function pause_from_boundary()
				observations.pause = observations.pause + 1
				observations.pause_result = fixture.engine.reset({
					suppress_telemetry = true,
				})
			end

			fixture.core.get_current_model = function()
				observations.model = observations.model + 1
				if boundary == "get_current_model" then pause_from_boundary() end
				return "fixture-model"
			end
			fixture.tooltip.show_loading = function()
				observations.loading = observations.loading + 1
				if boundary == "show_loading" then pause_from_boundary() end
				return true
			end
			fixture.core.fetch_llm_prediction = function(...)
				observations.fetch = observations.fetch + 1
				if boundary == "fetch" then pause_from_boundary() end
				local on_success = select(7, ...)
				on_success({ { to_type = " late", deletes = 0 } }, 1, true, false)
				return nil
			end

			helpers.assert_true(fixture.engine.start_timer(0))
			helpers.assert_eq(#fixture.timers, 1,
				"positive control must own exactly one real scheduler timer")
			local timer = fixture.timers[1]
			local fired_ok, fired_error = pcall(timer.callback)
			helpers.assert_true(fired_ok,
				"the real TimerScheduler boundary must contain delivery: "
					.. tostring(fired_error))

			helpers.assert_eq(observations.pause, 1)
			helpers.assert_eq(observations.pause_result, false,
				"PAUSE cannot settle while the naturally settled timer callback is on stack")
			helpers.assert_eq(observations.model, 1)
			helpers.assert_eq(observations.loading,
				boundary == "get_current_model" and 0 or 1,
				"a fenced dependency boundary cannot publish its loading sibling")
			helpers.assert_eq(observations.fetch,
				boundary == "fetch" and 1 or 0,
				"a fenced dependency boundary cannot dispatch a backend sibling")
			helpers.assert_eq(read_upvalue(fixture.engine.reset, "last_buffer_signature"), nil,
				"post-fetch revalidation must not republish the reset request signature")
			helpers.assert_eq(fixture.engine.is_visible(), false,
				"a success callback delivered after nested PAUSE must remain inert")
			helpers.assert_eq(#fixture.timers, 1,
				"fencing the predecessor cannot create an inactivity sibling")

			timer.callback()
			timer.callback()
			helpers.assert_eq(observations.pause, 1,
				"late and duplicate native delivery cannot replay timer business")
			helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }),
				"a retry after callback return must observe exact logical settlement")
		end)
	end

	helpers.it("stops an inactivity-owned fetch when stop_timer revokes only its owner", function()
		local fixture = load_fixture()
		local observations = {
			fetch = 0,
			loading = 0,
			stop_result = nil,
		}
		fixture.tooltip.show_loading = function()
			observations.loading = observations.loading + 1
			observations.stop_result = fixture.engine.stop_timer()
			return true
		end
		fixture.core.fetch_llm_prediction = function()
			observations.fetch = observations.fetch + 1
		end

		helpers.assert_true(fixture.engine.start_timer(0))
		local timer = fixture.timers[1]
		timer.callback()

		helpers.assert_eq(observations.loading, 1)
		helpers.assert_eq(observations.stop_result, false,
			"the in-stack timer owner cannot settle before its callback returns")
		helpers.assert_eq(observations.fetch, 0,
			"revoking only the continuation owner must fence the backend fetch")
		helpers.assert_eq(fixture.engine.is_visible(), false)
		timer.callback()
		timer.callback()
		helpers.assert_eq(observations.fetch, 0,
			"late and duplicate delivery cannot resurrect the revoked request")
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
	end)

	helpers.it("cannot rearm a direct rate-limit timer after its backend boundary resets", function()
		local fixture = load_fixture()
		local observations = {
			fetch = 0,
			reset_result = nil,
		}
		fixture.core.fetch_llm_prediction = function(...)
			observations.fetch = observations.fetch + 1
			local on_success = select(7, ...)
			on_success({ { to_type = " committed", deletes = 0 } }, 1, true, false)
		end
		fixture.engine.perform_check(true)
		helpers.assert_eq(observations.fetch, 1,
			"positive control must publish the request timestamp")

		fixture.now = 100.1
		fixture.rate_limit = 10
		local reenter = true
		fixture.core.get_backend = function()
			if reenter then
				reenter = false
				observations.reset_result = fixture.engine.reset({
					suppress_telemetry = true,
				})
			end
			return "mlx"
		end
		fixture.engine.perform_check(false)

		helpers.assert_true(observations.reset_result,
			"the direct dependency boundary must actually revoke the request")
		helpers.assert_eq(observations.fetch, 1,
			"the revoked request cannot dispatch a second backend call")
		helpers.assert_eq(#fixture.timers, 0,
			"the stale rate-limit branch cannot acquire an inactivity successor")
	end)

	helpers.it("preserves an inactivity successor installed during native settlement", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.engine.start_timer(0))
		fixture.reenter_on_running = function()
			return fixture.engine.start_timer(0)
		end

		helpers.assert_eq(fixture.engine.start_timer(0), false)
		helpers.assert_true(fixture.running_reentry_result)
		helpers.assert_eq(#fixture.timers, 2,
			"the outer start must not overwrite its nested inactivity successor")
		helpers.assert_eq(fixture.timers[1].live, false)
		helpers.assert_true(fixture.timers[2].live)
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
		helpers.assert_eq(fixture.timers[2].live, false)
	end)

	helpers.it("cannot publish chain_pending after fallback delivery during suppression", function()
		local fixture = load_fixture()
		local fetches = 0
		fixture.core.fetch_llm_prediction = function()
			fetches = fetches + 1
		end
		fixture.state.suppress_rescan_keep_buffer = function()
			helpers.assert_eq(#fixture.timers, 1,
				"the exact fallback must already be published at the suppression boundary")
			fixture.timers[1].callback()
			return true
		end

		helpers.assert_eq(fixture.engine.arm_chain(), false,
			"a fallback consumed before the arm transaction commits must reject the arm")
		helpers.assert_eq(fixture.engine.is_chain_pending(), false,
			"a consumed fallback cannot leave an unserviceable chain intent")
		helpers.assert_eq(fetches, 0,
			"pre-commit fallback delivery must remain business-inert")
		fixture.timers[1].callback()
		fixture.timers[1].callback()
		helpers.assert_eq(fetches, 0)
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects fallback delivery during suppression after stop "
			.. mode, function()
			local fixture = load_fixture()
			fixture.cancel_mode = mode
			fixture.state.suppress_rescan_keep_buffer = function()
				fixture.timers[1].callback()
				return true
			end

			helpers.assert_eq(fixture.engine.arm_chain(), false,
				"any pre-commit delivery attempt must reject the logical arm")
			helpers.assert_eq(fixture.engine.is_chain_pending(), false)
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_true(fixture.timers[1].live,
				"native stop refusal must retain the exact cleanup candidate")

			fixture.cancel_mode = nil
			fixture.state.suppress_rescan_keep_buffer = function() return true end
			helpers.assert_true(fixture.engine.arm_chain(),
				"retry must settle the delivered predecessor before one successor")
			helpers.assert_eq(fixture.timers[1].live, false)
			helpers.assert_eq(#fixture.timers, 2)
			helpers.assert_true(fixture.engine.is_chain_pending())
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects a " .. mode .. " chain suppression result exactly", function()
			local fixture = load_fixture()
			fixture.state.suppress_rescan_keep_buffer = function()
				if mode == "throw" then error("CHAIN_SUPPRESSION_THROW") end
				if mode == "false" then return false end
				return nil
			end

			helpers.assert_eq(fixture.engine.arm_chain(), false,
				"absence of an exact suppression commit must reject the chain arm")
			helpers.assert_eq(fixture.engine.is_chain_pending(), false)
			helpers.assert_eq(#fixture.timers, 1,
				"the failed transaction may only own its exact cleanup candidate")
			helpers.assert_eq(fixture.timers[1].live, false,
				"ordinary rollback must settle the exact fallback")
		fixture.timers[1].callback()
		fixture.timers[1].callback()
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
		end)
	end

	helpers.it("preserves a reentrant successor when the outer chain arm resumes", function()
		local fixture = load_fixture()
		local suppress_calls = 0
		local inner_result = nil
		fixture.state.suppress_rescan_keep_buffer = function()
			suppress_calls = suppress_calls + 1
			if suppress_calls == 1 then inner_result = fixture.engine.arm_chain() end
			return true
		end

		helpers.assert_eq(fixture.engine.arm_chain(), false,
			"the superseded outer attempt must reject its own commit")
		helpers.assert_true(inner_result,
			"the exact reentrant successor must remain committed")
		helpers.assert_true(fixture.engine.is_chain_pending())
		helpers.assert_eq(#fixture.timers, 2)
		helpers.assert_eq(fixture.timers[1].live, false,
			"the inner arm must settle the exact predecessor")
		helpers.assert_eq(fixture.timers[2].live, true,
			"outer rollback must not cancel the successor")
	end)

	helpers.it("preserves a chain successor installed during native stop proof", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.engine.arm_chain())
		fixture.reenter_on_running = function()
			return fixture.engine.arm_chain()
		end

		helpers.assert_eq(fixture.engine.arm_chain(), false,
			"the stale outer arm must refuse after native cleanup reentry")
		helpers.assert_true(fixture.running_reentry_result)
		helpers.assert_true(fixture.engine.is_chain_pending())
		helpers.assert_eq(#fixture.timers, 2)
		helpers.assert_eq(fixture.timers[1].live, false)
		helpers.assert_true(fixture.timers[2].live)
		helpers.assert_true(fixture.engine.handle_chain_signal(
			fixture.engine.KEYCODE_LLM_CHAIN))
		helpers.assert_eq(#fixture.timers, 3,
			"the preserved successor must remain consumable by the owned F16 signal")
		helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }))
	end)

	helpers.it("rejects F16 while the fallback arm is still uncommitted", function()
		local fixture = load_fixture()
		local signal_result = nil
		fixture.state.suppress_rescan_keep_buffer = function()
			signal_result = fixture.engine.handle_chain_signal(
				fixture.engine.KEYCODE_LLM_CHAIN)
			return true
		end

		helpers.assert_true(fixture.engine.arm_chain())
		helpers.assert_eq(signal_result, false,
			"F16 cannot consume an intent whose suppression boundary is still on stack")
		helpers.assert_true(fixture.engine.is_chain_pending())
		helpers.assert_eq(#fixture.timers, 1,
			"an uncommitted signal cannot acquire a dispatch sibling")
		helpers.assert_true(fixture.engine.handle_chain_signal(
			fixture.engine.KEYCODE_LLM_CHAIN))
		helpers.assert_eq(#fixture.timers, 2,
			"the same signal must dispatch exactly once after arm commit")
		helpers.assert_eq(fixture.engine.is_chain_pending(), false)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("clears chain intent after replacement start " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.engine.arm_chain())
			fixture.start_mode = mode
			helpers.assert_eq(fixture.engine.arm_chain(), false)
			helpers.assert_eq(fixture.engine.is_chain_pending(), false,
				"a refused replacement cannot inherit the predecessor intent")
			helpers.assert_eq(#fixture.timers, 2)
			helpers.assert_eq(fixture.timers[1].live, false)
			helpers.assert_eq(fixture.timers[2].live, false)
		fixture.timers[1].callback()
		fixture.timers[2].callback()
		end)

		helpers.it("retains exact cleanup but clears intent after replacement cancel "
			.. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.engine.arm_chain())
			local predecessor = fixture.timers[1]
			fixture.cancel_mode = mode
			helpers.assert_eq(fixture.engine.arm_chain(), false)
			helpers.assert_eq(fixture.engine.is_chain_pending(), false)
			helpers.assert_eq(#fixture.timers, 1,
				"cleanup refusal cannot acquire a sibling fallback")
			helpers.assert_true(predecessor.live)
		predecessor.callback()
			helpers.assert_eq(fixture.engine.is_chain_pending(), false)

		fixture.cancel_mode = nil
			helpers.assert_true(fixture.engine.arm_chain(),
				"retry must settle the same predecessor before acquiring one successor")
			helpers.assert_eq(predecessor.live, false)
			helpers.assert_eq(#fixture.timers, 2)
			helpers.assert_true(fixture.engine.is_chain_pending())
		end)
	end

	for _, kind in ipairs({ "fallback", "dispatch" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains the chain " .. kind .. " owner through " .. mode
				.. " model-boundary PAUSE", function()
				local fixture = load_fixture()
				local observations = {
					fetch = 0,
					model = 0,
					pause_result = nil,
				}
				fixture.core.get_current_model = function()
					observations.model = observations.model + 1
					observations.pause_result = fixture.engine.reset({
						suppress_telemetry = true,
					})
					if mode == "throw" then error("CHAIN_MODEL_BOUNDARY_THROW") end
					if mode == "false" then return false end
					return nil
				end
				fixture.core.fetch_llm_prediction = function()
					observations.fetch = observations.fetch + 1
				end

				helpers.assert_true(fixture.engine.arm_chain())
				local timer = fixture.timers[1]
				local expected_timer_count = 1
				if kind == "dispatch" then
					helpers.assert_true(fixture.engine.handle_chain_signal(
						fixture.engine.KEYCODE_LLM_CHAIN))
					timer = fixture.timers[2]
					expected_timer_count = 2
				end

				local fired_ok, fired_error = pcall(timer.callback)
				helpers.assert_true(fired_ok,
					"chain callback failure must stay inside the real scheduler: "
						.. tostring(fired_error))
				helpers.assert_eq(observations.pause_result, false,
					"PAUSE cannot settle while chain business is on stack")
				helpers.assert_eq(observations.model, 1)
				helpers.assert_eq(observations.fetch, 0,
					"the fenced chain cannot dispatch after its model boundary")
				helpers.assert_eq(fixture.engine.is_chain_pending(), false)
				helpers.assert_eq(#fixture.timers, expected_timer_count,
					"chain settlement cannot create a fallback or dispatch sibling")

				timer.callback()
				timer.callback()
				helpers.assert_eq(observations.model, 1,
					"late and duplicate chain delivery cannot replay business")
				helpers.assert_true(fixture.engine.reset({ suppress_telemetry = true }),
					"chain ownership must release exactly after callback return")
			end)
		end
	end
end)
