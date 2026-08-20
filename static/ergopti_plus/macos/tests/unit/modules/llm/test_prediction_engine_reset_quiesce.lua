--- tests/unit/modules/llm/test_prediction_engine_reset_quiesce.lua

--- ==============================================================================
--- MODULE: Regression — reset() fully quiesces stream + deferred state
--- DESCRIPTION:
--- Audit findings F-L11 and F-L12.
---   F-L11: reset() gated core_llm.cancel_streaming() behind is_streaming_enabled,
---          so toggling streaming OFF while a stream was in flight left the curl
---          task running (and on MLX held the single-request connection). Cancel
---          must be UNCONDITIONAL (it is a null-safe no-op when nothing streams).
---   F-L12: reset() never cleared _deferred_profile_name, so a rate-limit deferral
---          torn down by reset() leaked a stale profile label into the NEXT
---          unrelated prediction's info bar. reset() must clear it.
--- This test drives the real reset implementation with fault-observable ports;
--- source greps previously went green without proving that cancellation ran.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_fixture(cancel_result)
	helpers.load_with_stubs("infra.logger")
	local cancel_calls = 0
	local core = {
		DEFAULT_STATE = {
			llm_enabled = false,
			llm_temperature = 0.1,
			llm_context_length = 4000,
			llm_min_words = 1,
			llm_max_words = 0,
			llm_num_predictions = 1,
			llm_pred_indent = 0,
			llm_val_modifiers = {},
			llm_nav_modifiers = {},
			llm_show_info_bar = false,
			llm_sequential_mode = false,
			llm_debounce = 0.1,
			llm_disable_url_bars = false,
			llm_disable_password_fields = true,
			llm_auto_raise_temp = false,
			llm_streaming = false,
			llm_streaming_multi = false,
			llm_instant_on_word_end = false,
		},
		get_current_model = function() return "test-model" end,
		get_backend = function() return "ollama" end,
		get_active_profile = function() return nil end,
		set_runtime_llm_enabled = function() end,
		set_llm_streaming = function() end,
		cancel_streaming = function()
			cancel_calls = cancel_calls + 1
			if type(cancel_result) == "function" then return cancel_result() end
			if cancel_result ~= nil then return cancel_result end
			return true
		end,
	}
	package.loaded["modules.llm"] = core
	package.loaded["modules.llm.warmup_controller"] = {
		init = function() return true end,
		stop = function() end,
		schedule_warmup_with_retry = function() end,
	}
	package.loaded["modules.llm.prompt_builder"] = { build = function() return nil end }
	package.loaded["modules.llm.streaming_handler"] = {
		init = function() return true end,
		stop_watchdog = function() return true end,
		reset_failure_count = function() end,
	}
	package.loaded["modules.llm.app_filter"] = { is_blocked = function() return false end }
	package.loaded["modules.llm.api_common"] = { get_rate_limit_min_interval_s = function() return 0 end }
	package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm_dismissed = function() end,
	}
	package.loaded["ui.tooltip"] = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		mark_chain_complete = function() return true end,
		hide_forced_silent = function() return true end,
		get_current_index = function() return nil end,
	}

	package.loaded["modules.llm.prediction_engine"] = nil
	local engine = require("modules.llm.prediction_engine")
	engine.init({ buffer = "", mappings = {}, DELAYS = { llm_prediction = 0 } })
	engine.set_llm_streaming(false)
	return engine, function() return cancel_calls end
end

local function find_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return index, value end
	end
	return nil, nil
end

helpers.describe("prediction_engine.reset() quiesces stream + deferred state", function()
	helpers.it("F-L11: cancels streaming UNCONDITIONALLY (not gated on is_streaming_enabled)", function()
		local engine, cancel_calls = load_fixture()
		helpers.assert_eq(cancel_calls(), 0)
		helpers.assert_eq(engine.reset(), true)
		helpers.assert_eq(cancel_calls(), 1,
			"reset must call the real backend cancellation port even while streaming is configured off")
	end)

	helpers.it("F-L12: clears _deferred_profile_name", function()
		local engine = load_fixture()
		local index = find_upvalue(engine.reset, "_deferred_profile_name")
		helpers.assert_not_nil(index,
			"the behavioral negative control must reach the real deferred-profile slot")
		debug.setupvalue(engine.reset, index, "stale-profile")
		helpers.assert_eq(engine.reset(), true)
		local _, value = find_upvalue(engine.reset, "_deferred_profile_name")
		helpers.assert_eq(value, nil,
			"reset must clear the live slot, not merely carry a source line that looks correct")
	end)

	for _, case in ipairs({
		{ name = "false", value = false },
		{ name = "throw", value = function() error("backend cancel failed") end },
	}) do
		helpers.it("stop_timer contains and propagates a backend " .. case.name, function()
			local engine, cancel_calls = load_fixture(case.value)
			local ok, result = pcall(engine.stop_timer)
			helpers.assert_true(ok, "timer teardown must not throw into the eventtap: " .. tostring(result))
			helpers.assert_eq(result, false)
			helpers.assert_eq(cancel_calls(), 1)
		end)
	end

	helpers.it("retains a no-op inactivity timer stop as retryable reset state", function()
		local engine = load_fixture()
		local _, stop_timer = find_upvalue(engine.reset, "stop_inactivity_timer")
		helpers.assert_eq(type(stop_timer), "function",
			"the negative control must reach the real timer teardown helper")
		local timer_index = find_upvalue(stop_timer, "_inactivity_timer")
		helpers.assert_not_nil(timer_index)

		local running = true
		local stop_calls = 0
		local timer = {
			stop = function()
				stop_calls = stop_calls + 1
				if stop_calls > 1 then running = false end
			end,
			running = function() return running end,
		}
		debug.setupvalue(stop_timer, timer_index, timer)

		helpers.assert_eq(engine.reset(), false,
			"reset cannot commit while its debounce callback remains armed")
		helpers.assert_eq(running, true)
		helpers.assert_eq(engine.reset(), true,
			"the canonical retained timer must be retried by the next reset")
		helpers.assert_eq(running, false)
		helpers.assert_eq(stop_calls, 2)
	end)

	helpers.it("rejects and retries a no-op inactivity timer start", function()
		local engine = load_fixture()
		engine.set_llm_enabled(true)
		local _, start_timer = find_upvalue(engine.start_timer, "start_inactivity_timer")
		helpers.assert_eq(type(start_timer), "function")
		local timer_index = find_upvalue(start_timer, "_inactivity_timer")
		helpers.assert_not_nil(timer_index)

		local running = false
		local start_calls = 0
		local timer = {
			start = function()
				start_calls = start_calls + 1
				if start_calls > 1 then running = true end
			end,
			stop = function() running = false end,
			running = function() return running end,
		}
		debug.setupvalue(start_timer, timer_index, timer)

		helpers.assert_eq(engine.start_timer(), false,
			"a returned start call is not ownership while native state stays stopped")
		helpers.assert_eq(engine.start_timer_word_end(), true,
			"the canonical handle must remain available for the next retry")
		helpers.assert_eq(running, true)
		helpers.assert_eq(start_calls, 2)
	end)

	helpers.it("contains a throwing inactivity timer start", function()
		local engine = load_fixture()
		engine.set_llm_enabled(true)
		local _, start_timer = find_upvalue(engine.start_timer, "start_inactivity_timer")
		local timer_index = find_upvalue(start_timer, "_inactivity_timer")
		debug.setupvalue(start_timer, timer_index, {
			start = function() error("START_THROW") end,
			stop = function() end,
			running = function() return false end,
		})

		local ok, result = pcall(engine.start_timer)
		helpers.assert_true(ok, "timer start failure must not escape into an eventtap")
		helpers.assert_eq(result, false)
	end)
end)
