--- tests/unit/modules/llm/test_prediction_engine_action_epoch_guard.lua

--- ==============================================================================
--- MODULE: Prediction-engine action-epoch quarantine behavioural regressions
--- DESCRIPTION:
--- Drives the real prediction engine and real streaming handler around a captured
--- backend request. Once the live action-epoch predicate closes, every callback
--- created for that request (partial, success, failure, watchdog and debounce)
--- must become a no-op before it mutates refs, persists telemetry, logs, or paints.
--- ==============================================================================

local helpers = require("tests.helpers")


local DEFAULTS = {
	llm_enabled = false,
	llm_temperature = 0.1,
	llm_context_length = 4000,
	llm_min_words = 2,
	llm_max_words = 0,
	llm_num_predictions = 3,
	llm_pred_indent = 0,
	llm_val_modifiers = { "alt" },
	llm_nav_modifiers = { "ctrl" },
	llm_show_info_bar = true,
	llm_sequential_mode = false,
	llm_debounce = 0.3,
	llm_auto_raise_temp = false,
	llm_streaming = false,
	llm_streaming_multi = false,
	llm_instant_on_word_end = false,
}


local function load_fixture(streaming)
	helpers.load_with_stubs("infra.logger")
	hs.application.frontmostApplication = function()
		return { title = function() return "FixtureApp" end }
	end

	local effects = {
		logs = 0,
		renders = 0,
		hides = 0,
		timing_paints = 0,
		keylogger_writes = 0,
	}
	local fetches = 0
	local captured = {}
	local available = true

	local Logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
		Logger[level] = function() effects.logs = effects.logs + 1 end
	end
	package.loaded["infra.logger"] = Logger
	package.loaded["infra.timings"] = {
		sec = function(_section, key)
			if key == "stream_watchdog_ms" then return 7 end
			if key == "chain_fallback_ms" then return 1 end
			if key == "prediction_debounce_min_ms" then return 0.01 end
			if key == "prediction_debounce_max_ms" then return 2 end
			return 0.1
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
	}
	package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, callback)
			return { timer = { stop = function() end }, callback = callback }
		end,
	}

	local core = {
		DEFAULT_STATE = DEFAULTS,
		get_current_model = function() return "test-model" end,
		get_backend = function() return "ollama" end,
		get_active_profile = function() return { label = "Test" } end,
		is_backend_ready = function() return true end,
		set_runtime_llm_enabled = function() end,
		set_llm_streaming = function() end,
		cancel_streaming = function() return true end,
		fetch_llm_prediction = function(...)
			fetches = fetches + 1
			captured.success = select(7, ...)
			captured.fail = select(8, ...)
			captured.partial = select(12, ...)
		end,
	}
	package.loaded["modules.llm"] = core
	package.loaded["modules.llm.warmup_controller"] = {
		init = function() end,
		start = function() end,
		stop = function() end,
		schedule_warmup_with_retry = function() end,
	}
	package.loaded["modules.llm.prompt_builder"] = {
		build = function()
			return {
				context_buffer = "hello wor",
				tail = "wor",
				req_temperature = 0.1,
				max_tokens = 32,
				num_preds = 3,
			}, nil, "signature"
		end,
	}
	package.loaded["modules.llm.parser"] = {
		strip_thinking = function(raw) return raw end,
		process_prediction = function(_buffer, _tail, raw)
			return {
				to_type = " " .. tostring(raw),
				deletes = 0,
				chunks = { { type = "insert", text = " " .. tostring(raw) } },
				nw = "",
				has_corrections = false,
			}
		end,
	}
	package.loaded["modules.llm.app_filter"] = {
		is_blocked = function() return false end,
	}
	package.loaded["modules.llm.api_common"] = {
		MIN_CALL_INTERVAL_SEC = 0,
		get_retry_policy = function() return 1, 0, 1 end,
		get_rate_limit_min_interval_s = function() return 0 end,
	}
	package.loaded["modules.shortcuts.script_control"] = nil

	local tooltip = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		set_chain_start = function() return true end,
		set_llm_timeout = function() end,
		reset_llm_timer = function() return true end,
		show_loading = function() effects.renders = effects.renders + 1; return true end,
		show_predictions = function() effects.renders = effects.renders + 1; return true end,
		hide = function() effects.hides = effects.hides + 1 end,
		hide_forced = function() effects.hides = effects.hides + 1 end,
		mark_chain_complete = function() effects.timing_paints = effects.timing_paints + 1; return true end,
		make_diff_styled = function() return true end,
		get_current_index = function() return 1 end,
		navigate = function() return true end,
		tint = function() return nil end,
	}
	package.loaded["ui.tooltip"] = tooltip
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() effects.keylogger_writes = effects.keylogger_writes + 1 end,
		log_llm_suggested = function() effects.keylogger_writes = effects.keylogger_writes + 1 end,
		log_llm_dismissed = function() effects.keylogger_writes = effects.keylogger_writes + 1 end,
	}

	package.loaded["modules.llm.streaming_handler"] = nil
	package.loaded["modules.llm.prediction_engine"] = nil
	local PE = require("modules.llm.prediction_engine")
	PE.set_runtime_guard(function() return available end)
	PE.init({
		buffer = "hello wor",
		mappings = {},
		DELAYS = { llm_prediction = 0 },
		suppress_rescan_keep_buffer = function() end,
	})
	PE.set_llm_enabled(true)
	if streaming then
		PE.set_llm_streaming(true)
		PE.set_llm_streaming_multi(true)
	end

	local function clear_effects()
		for key in pairs(effects) do effects[key] = 0 end
	end
	local function set_available(value) available = value == true end
	local function dispatch()
		PE.perform_check(true)
		return fetches
	end
	return PE, effects, captured, set_available, clear_effects, dispatch,
		function() return fetches end
end


local function prediction(text)
	return {
		to_type = text,
		deletes = 0,
		chunks = { { type = "insert", text = text } },
		nw = "",
		has_corrections = false,
	}
end


local function effect_total(effects)
	return effects.logs + effects.renders + effects.hides
		+ effects.timing_paints + effects.keylogger_writes
end


local function effect_summary(effects)
	return string.format(
		"logs=%d renders=%d hides=%d timing=%d keylogger=%d",
		effects.logs, effects.renders, effects.hides,
		effects.timing_paints, effects.keylogger_writes
	)
end


helpers.describe("prediction_engine: action-epoch quarantine closes async producers", function()
	helpers.it("positive controls prove every captured producer is live while the epoch is open", function()
		local PE, success_effects, success_callbacks, _, clear_success, success_dispatch = load_fixture(false)
		helpers.assert_eq(success_dispatch(), 1)
		clear_success()
		success_callbacks.success({ prediction(" completion") }, 25, true, false)
		helpers.assert_true(effect_total(success_effects) > 0,
			"the success callback must have observable effects before its stale twin is tested")
		helpers.assert_eq(#PE.get_predictions(), 1)
		helpers.assert_true(PE.is_visible())

		local PE_partial, partial_effects, partial_callbacks, _, clear_partial, partial_dispatch = load_fixture(true)
		helpers.assert_eq(partial_dispatch(), 1)
		clear_partial()
		partial_callbacks.partial("partial token")
		helpers.assert_true(effect_total(partial_effects) > 0,
			"the partial callback must have observable effects while open")
		helpers.assert_eq(#PE_partial.get_predictions(), 1)

		local _, fail_effects, fail_callbacks, _, clear_fail, fail_dispatch = load_fixture(false)
		helpers.assert_eq(fail_dispatch(), 1)
		clear_fail()
		fail_callbacks.fail()
		helpers.assert_true(effect_total(fail_effects) > 0,
			"the failure callback must have observable effects while open")

		local _, watchdog_effects, watchdog_callbacks, _, clear_watchdog, watchdog_dispatch = load_fixture(true)
		helpers.assert_eq(watchdog_dispatch(), 1)
		watchdog_callbacks.partial("watchdog seed")
		local watchdog
		for _, timer in ipairs(hs.timer.__timers) do
			if timer.delay == 7 then watchdog = timer; break end
		end
		helpers.assert_not_nil(watchdog)
		clear_watchdog()
		watchdog:fire()
		helpers.assert_true(effect_total(watchdog_effects) > 0,
			"the watchdog must be executable before its stale twin is tested")

		local PE_debounce, _, _, _, _, _, get_debounce_fetches = load_fixture(false)
		PE_debounce.start_timer(0.02)
		local debounce = hs.timer.__timers[1]
		helpers.assert_not_nil(debounce)
		debounce:fire()
		helpers.assert_eq(get_debounce_fetches(), 1,
			"the debounce must dispatch while open before its stale twin is tested")
	end)


	helpers.it("a debounce timer armed by an old epoch cannot dispatch a fetch", function()
		local PE, effects, _, set_available, clear_effects, _, get_fetches = load_fixture(false)
		PE.start_timer(0.02)
		local debounce = hs.timer.__timers[1]
		helpers.assert_not_nil(debounce, "the engine must own a real delayed debounce timer")
		helpers.assert_true(debounce.running, "positive control: start_timer must arm it")
		set_available(false)
		clear_effects()
		debounce:fire()
		helpers.assert_eq(get_fetches(), 0,
			"the stale debounce callback must be rejected before backend dispatch")
		helpers.assert_eq(effect_total(effects), 0, effect_summary(effects))
	end)


	helpers.it("a stale success callback cannot mutate, log, persist, or render", function()
		local PE, effects, callbacks, set_available, clear_effects, dispatch = load_fixture(false)
		helpers.assert_eq(dispatch(), 1, "positive control: one backend request must be captured")
		helpers.assert_eq(type(callbacks.success), "function")
		set_available(false)
		clear_effects()
		callbacks.success({ prediction(" completion") }, 25, true, false)
		set_available(true)
		helpers.assert_eq(effect_total(effects), 0,
			"stale success escaped quarantine: " .. effect_summary(effects))
		helpers.assert_eq(#PE.get_predictions(), 0,
			"a stale success must not populate the engine pool for later resurrection")
		helpers.assert_eq(PE.is_visible(), false,
			"reopening the gate must not resurrect a completion received while closed")
	end)


	helpers.it("a stale partial callback cannot mutate, log, persist, or render", function()
		local PE, effects, callbacks, set_available, clear_effects, dispatch = load_fixture(true)
		helpers.assert_eq(dispatch(), 1)
		helpers.assert_eq(type(callbacks.partial), "function",
			"streaming multi mode must expose the partial callback under test")
		set_available(false)
		clear_effects()
		callbacks.partial("partial token")
		set_available(true)
		helpers.assert_eq(effect_total(effects), 0,
			"stale partial escaped quarantine: " .. effect_summary(effects))
		helpers.assert_eq(#PE.get_predictions(), 0,
			"a stale partial must not populate streaming placeholders")
		helpers.assert_eq(PE.is_visible(), false)
	end)


	helpers.it("a stale failure callback cannot log or mutate the visible surface", function()
		local _, effects, callbacks, set_available, clear_effects, dispatch = load_fixture(false)
		helpers.assert_eq(dispatch(), 1)
		helpers.assert_eq(type(callbacks.fail), "function")
		set_available(false)
		clear_effects()
		callbacks.fail()
		helpers.assert_eq(effect_total(effects), 0,
			"stale failure escaped quarantine: " .. effect_summary(effects))
	end)


	helpers.it("the stream watchdog rechecks the live epoch before logging or rendering", function()
		local _, effects, callbacks, set_available, clear_effects, dispatch = load_fixture(true)
		helpers.assert_eq(dispatch(), 1)
		callbacks.partial("positive control")
		local watchdog
		for _, timer in ipairs(hs.timer.__timers) do
			if timer.delay == 7 then watchdog = timer; break end
		end
		helpers.assert_not_nil(watchdog, "perform_check must arm the real stream watchdog")
		helpers.assert_true(watchdog.running)
		set_available(false)
		clear_effects()
		watchdog:fire()
		helpers.assert_eq(effect_total(effects), 0,
			"stale watchdog escaped quarantine: " .. effect_summary(effects))
	end)
end)
