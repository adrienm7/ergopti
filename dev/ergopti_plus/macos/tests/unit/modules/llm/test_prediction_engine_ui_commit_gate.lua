--- tests/unit/modules/llm/test_prediction_engine_ui_commit_gate.lua

--- ==============================================================================
--- MODULE: Prediction-engine UI commit gate regressions
--- DESCRIPTION:
--- Drives the real prediction engine with a controllable tooltip. A backend
--- request, watchdog, timing chain, or duplicate-suppression signature must not
--- be committed until the loading surface reports strict success. Failed,
--- missing, and throwing UI results must close only the generation that still
--- owns the attempt, while a deliberately disabled preview remains a quiet
--- no-request state.
--- ==============================================================================

local helpers = require("tests.helpers")

local NIL_RESULT = {}

--- Resolves a configured dependency outcome while preserving an explicit nil.
--- @param configured any Configured value, function, or NIL_RESULT sentinel.
--- @param default any Default when no value was configured.
--- @return any result Resolved outcome.
local function resolve_result(configured, default)
	if configured == NIL_RESULT then return nil end
	if configured == nil then return default end
	if type(configured) == "function" then return configured() end
	return configured
end


local DEFAULTS = {
	llm_enabled = false,
	llm_temperature = 0.1,
	llm_context_length = 4000,
	llm_min_words = 1,
	llm_max_words = 0,
	llm_num_predictions = 2,
	llm_pred_indent = 0,
	llm_val_modifiers = { "alt" },
	llm_nav_modifiers = { "ctrl" },
	llm_show_info_bar = false,
	llm_sequential_mode = false,
	llm_debounce = 0.2,
	llm_auto_raise_temp = false,
	llm_streaming = false,
	llm_streaming_multi = false,
	llm_instant_on_word_end = false,
	llm_disable_url_bars = false,
	llm_disable_password_fields = true,
}


--- Loads one real prediction engine with observable UI and backend ports.
--- @param loading_result any|function Result returned by tooltip.show_loading.
--- @param options table|nil Optional outcomes for later dispatch stages.
--- @return table fixture Observable fixture fields and the loaded engine.
local function load_fixture(loading_result, options)
	options = options or {}
	helpers.load_with_stubs("infra.logger")

	local fixture = {
		builds = 0,
		fetches = 0,
		watchdogs = 0,
		chain_starts = 0,
		hides = 0,
		cancels = 0,
		watchdog_stops = 0,
		loading_calls = 0,
		tint_calls = 0,
	}
	fixture.options = options

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_section, key)
			if key == "prediction_debounce_min_ms" then return 0.01 end
			if key == "prediction_debounce_max_ms" then return 2 end
			return 0.1
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, callback)
			return { timer = { stop = function() end }, callback = callback }, true
		end,
	}

	local core = {
		DEFAULT_STATE = DEFAULTS,
		get_current_model = function() return "test-model" end,
		get_backend = function() return "ollama" end,
		get_active_profile = function() return nil end,
		is_backend_ready = function() return true end,
		set_runtime_llm_enabled = function() end,
		set_llm_streaming = function() end,
		cancel_streaming = function() fixture.cancels = fixture.cancels + 1; return true end,
		fetch_llm_prediction = function(_context, _tail, _model, _temperature, _max_tokens,
			_num_predictions, on_success, on_fail, _sequential, _force, _request_id, on_partial)
			fixture.fetches = fixture.fetches + 1
			fixture.on_success = on_success
			fixture.on_fail = on_fail
			fixture.on_partial = on_partial
			return resolve_result(options.fetch_result, true)
		end,
	}
	package.loaded["modules.llm"] = core
	package.loaded["modules.llm.warmup_controller"] = {
		init = function() return true end,
		stop = function() end,
		schedule_warmup_with_retry = function() end,
	}
	package.loaded["modules.llm.prompt_builder"] = {
		build = function()
			fixture.builds = fixture.builds + 1
			return {
				context_buffer = "hello world",
				tail = "world",
				req_temperature = 0.1,
				max_tokens = 16,
				num_preds = 2,
			}, nil, "signature"
		end,
	}
	package.loaded["modules.llm.streaming_handler"] = {
		init = function() return true end,
		build_callbacks = function()
			if options.callback_factory_error then error("callback factory failed") end
			if options.callback_factory_invalid then return nil, nil, nil end
			local partial = options.callback_error == "partial" and function()
				error("partial callback dependency failed")
			end or nil
			local success = function()
				if options.callback_error == "success" then error("success callback dependency failed") end
			end
			local failure = function()
				if options.callback_error == "failure" then error("failure callback dependency failed") end
			end
			return partial, success, failure
		end,
		arm_watchdog = function()
			fixture.watchdogs = fixture.watchdogs + 1
			return resolve_result(options.watchdog_result, true)
		end,
		stop_watchdog = function()
			fixture.watchdog_stops = fixture.watchdog_stops + 1
			return true
		end,
		reset_failure_count = function() end,
	}
	package.loaded["modules.llm.app_filter"] = { is_blocked = function() return false end }
	package.loaded["modules.llm.api_common"] = {
		get_rate_limit_min_interval_s = function() return options.min_interval or 0 end,
	}
	package.loaded["modules.shortcuts.script_control"] = nil
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm_dismissed = function() end,
	}

	local tooltip = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		set_llm_timeout = function() end,
		set_chain_start = function()
			fixture.chain_starts = fixture.chain_starts + 1
			return resolve_result(options.chain_result, true)
		end,
		show_loading = function()
			fixture.loading_calls = fixture.loading_calls + 1
			if type(loading_result) == "function" then return loading_result() end
			return loading_result
		end,
		hide_forced_silent = function()
			fixture.hides = fixture.hides + 1
			return resolve_result(options.hide_result, true)
		end,
		mark_chain_complete = function() return true end,
		tint = function()
			fixture.tint_calls = fixture.tint_calls + 1
			return resolve_result(options.tint_result, nil)
		end,
	}
	package.loaded["ui.tooltip"] = tooltip

	package.loaded["modules.llm.prediction_engine"] = nil
	local Engine = require("modules.llm.prediction_engine")
	fixture.engine = Engine
	fixture.tooltip = tooltip
	Engine.init({
		buffer = "hello world",
		mappings = {},
		DELAYS = { llm_prediction = 1 },
		suppress_rescan_keep_buffer = function() end,
	})
	Engine.set_llm_enabled(true)
	return fixture
end





-- ==========================================================
-- ==========================================================
-- ======= 1/ Initial Loading Surface Commit Gate ===========
-- ==========================================================
-- ==========================================================

helpers.describe("prediction_engine: loading UI is the request commit gate", function()
	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = nil },
		{ name = "throw", value = function() error("canvas failed") end },
	}) do
		helpers.it("rejects a " .. case.name .. " loading result before any backend work", function()
			local fixture = load_fixture(case.value)
			fixture.engine.perform_check(true)

			helpers.assert_eq(fixture.loading_calls, 1,
				"the negative control must reach the real loading call")
			helpers.assert_eq(fixture.chain_starts, 0,
				"chain timing must not arm before the loading surface commits")
			helpers.assert_eq(fixture.watchdogs, 0,
				"the watchdog must not arm for a request the user cannot see")
			helpers.assert_eq(fixture.fetches, 0,
				"the backend must not run for a request whose UI commit failed")
			helpers.assert_eq(fixture.hides, 1,
				"the still-current failed attempt must fail closed through one reset")

			fixture.tooltip.show_loading = function()
				fixture.loading_calls = fixture.loading_calls + 1
				return true
			end
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 1,
				"a failed UI commit must not consume the buffer signature and block a retry")
		end)
	end

	helpers.it("does not reset a newer generation created during a failing show", function()
		local fixture
		fixture = load_fixture(function()
			fixture.engine.reset()
			return false
		end)
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.hides, 1,
			"the failure handler must not reset again after the show invalidated its generation")
	end)

	helpers.it("keeps a deliberately disabled AI preview fully idle", function()
		local fixture = load_fixture(true)
		fixture.engine.set_preview_ai_enabled(false)
		fixture.builds = 0
		fixture.loading_calls = 0
		fixture.hides = 0
		fixture.cancels = 0
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.builds, 0,
			"preview-disabled mode must stop before prompt construction")
		helpers.assert_eq(fixture.loading_calls, 0)
		helpers.assert_eq(fixture.watchdogs, 0)
		helpers.assert_eq(fixture.fetches, 0)
		helpers.assert_eq(fixture.hides, 0,
			"the quiet disabled path must not be misclassified as a UI failure")
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ Whole Async Callback Containment ==============
-- ==========================================================
-- ==========================================================

helpers.describe("prediction_engine: async callback failures revoke request ownership", function()
	for _, case in ipairs({
		{
			name = "success",
			invoke = function(fixture) fixture.on_success({}, 1, true, false) end,
		},
		{
			name = "failure",
			invoke = function(fixture) fixture.on_fail() end,
		},
		{
			name = "partial",
			invoke = function(fixture) fixture.on_partial("partial") end,
		},
	}) do
		helpers.it("contains a throwing " .. case.name .. " callback and closes its surface", function()
			local fixture = load_fixture(true, { callback_error = case.name })
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 1)

			-- Call through the real callback boundary. Any escape fails the test
			-- directly; the state assertions below prove cleanup also committed.
			case.invoke(fixture)
			helpers.assert_eq(fixture.hides, 1,
				"a callback dependency throw must revoke the loading/prediction surface")
			helpers.assert_eq(fixture.cancels, 1,
				"cleanup must cancel the request whose callback can no longer complete")
			helpers.assert_eq(fixture.watchdog_stops, 1,
				"cleanup must stop the watchdog rather than leave a late callback armed")
		end)
	end

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "throw", value = function() error("native hide failed") end },
	}) do
		helpers.it("continues cancellation when cleanup hide returns " .. case.name, function()
			local fixture = load_fixture(true, {
				callback_error = "success",
				hide_result = case.value,
			})
			fixture.engine.perform_check(true)

			fixture.on_success({}, 1, true, false)
			helpers.assert_eq(fixture.hides, 1,
				"the strict hide negative control must reach the real cleanup stage")
			helpers.assert_eq(fixture.watchdog_stops, 1,
				"watchdog cancellation is a sibling cleanup stage, not hide-dependent")
			helpers.assert_eq(fixture.cancels, 1,
				"backend cancellation must still execute after a native hide failure")
		end)
	end
end)





-- ==========================================================
-- ==========================================================
-- ======= 2/ Downstream Dispatch Commit Gates ==============
-- ==========================================================
-- ==========================================================

helpers.describe("prediction_engine: every pre-fetch stage commits strictly", function()
	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = NIL_RESULT },
		{ name = "throw", value = function() error("chain clock failed") end },
	}) do
		helpers.it("rejects a " .. case.name .. " chain-timing result", function()
			local fixture = load_fixture(true, { chain_result = case.value })
			fixture.engine.perform_check(true)

			helpers.assert_eq(fixture.loading_calls, 1)
			helpers.assert_eq(fixture.chain_starts, 1,
				"the negative control must reach the production chain-timing call")
			helpers.assert_eq(fixture.watchdogs, 0)
			helpers.assert_eq(fixture.fetches, 0)
			helpers.assert_eq(fixture.hides, 1,
				"a failed timing commit must close the loading surface")
		end)
	end

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "nil", value = NIL_RESULT },
		{ name = "throw", value = function() error("timer creation failed") end },
	}) do
		helpers.it("rejects a " .. case.name .. " watchdog-arm result", function()
			local fixture = load_fixture(true, { watchdog_result = case.value })
			fixture.engine.perform_check(true)

			helpers.assert_eq(fixture.loading_calls, 1)
			helpers.assert_eq(fixture.chain_starts, 1)
			helpers.assert_eq(fixture.watchdogs, 1,
				"the negative control must reach the watchdog boundary")
			helpers.assert_eq(fixture.fetches, 0,
				"backend dispatch requires a proven live watchdog")
			helpers.assert_eq(fixture.hides, 1)
		end)
	end

	helpers.it("contains a tint throw inside the loading-render transaction", function()
		local fixture = load_fixture(true, {
			tint_result = function() error("native tint failed") end,
		})
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.tint_calls, 1,
			"the negative control must throw while constructing real render arguments")
		helpers.assert_eq(fixture.loading_calls, 0,
			"show_loading cannot run after its tint argument failed")
		helpers.assert_eq(fixture.watchdogs, 0)
		helpers.assert_eq(fixture.fetches, 0)
		helpers.assert_eq(fixture.hides, 1,
			"an argument-construction throw must use the same fail-closed reset")
	end)

	helpers.it("closes the surface when backend dispatch throws synchronously", function()
		local fixture = load_fixture(true, {
			fetch_result = function() error("backend dispatch failed") end,
		})
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.watchdogs, 1)
		helpers.assert_eq(fixture.fetches, 1,
			"the negative control must reach the real backend dispatch boundary")
		helpers.assert_eq(fixture.hides, 1,
			"a synchronous dispatcher throw must not strand the loading surface")
	end)

	helpers.it("closes the live loading surface when callback construction throws", function()
		local fixture = load_fixture(true, { callback_factory_error = true })
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.loading_calls, 1)
		helpers.assert_eq(fixture.watchdogs, 0,
			"no watchdog exists until callback construction commits")
		helpers.assert_eq(fixture.fetches, 0,
			"a backend request cannot be owned without completion callbacks")
		helpers.assert_eq(fixture.hides, 1,
			"the already-painted loading surface must be revoked")
		helpers.assert_eq(fixture.cancels, 1,
			"cleanup must still cancel any backend capability defensively")
	end)

	helpers.it("rejects an inert callback set before backend dispatch", function()
		local fixture = load_fixture(true, { callback_factory_invalid = true })
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.fetches, 0,
			"an uninitialised handler must not dispatch callbacks that can never settle")
		helpers.assert_eq(fixture.watchdogs, 0)
		helpers.assert_eq(fixture.hides, 1,
			"the loading surface must be revoked when callback ownership is absent")
	end)

	helpers.it("does not rate-limit a retry after watchdog construction failed", function()
		local fixture = load_fixture(true, {
			watchdog_result = false,
			min_interval = 60,
		})
		fixture.engine.perform_check(false)
		helpers.assert_eq(fixture.fetches, 0,
			"the negative control must fail before backend dispatch")

		fixture.options.watchdog_result = true
		fixture.engine.perform_check(false)
		helpers.assert_eq(fixture.fetches, 1,
			"a failed pre-dispatch attempt must not consume the backend rate-limit window")
	end)
end)
