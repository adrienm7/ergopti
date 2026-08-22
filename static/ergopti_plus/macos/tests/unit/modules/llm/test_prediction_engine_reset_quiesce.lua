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
	local hs_stub = _G.hs
	package.loaded["adapters.timer_scheduler"] = nil
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
	return engine, function() return cancel_calls end, hs_stub
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

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a " .. mode
			.. " inactivity timer stop as retryable reset state", function()
			local engine, _, hs_stub = load_fixture()
			engine.set_llm_enabled(true)
			local calls = 0
			local real_perform = engine.perform_check
			engine.perform_check = function() calls = calls + 1 end
			local original_new = hs_stub.timer.new
			local stop_calls = 0
			local allow_stop = false
			local live = false
			local timer, native_callback
			hs_stub.timer.new = function(delay, callback)
				native_callback = callback
				timer = {
					delay = delay,
					start = function(self)
						live = true
						return self
					end,
					running = function() return live end,
				}
				timer.stop = function(self)
					stop_calls = stop_calls + 1
					if allow_stop then live = false; return self end
					if mode == "throw" then error("INACTIVITY_STOP_THROW") end
					if mode == "nil" then return nil end
					return false
				end
				return timer
			end
			helpers.assert_eq(engine.start_timer(), true)
			hs_stub.timer.new = original_new

			helpers.assert_eq(engine.reset(), false,
				"reset cannot commit while its debounce callback remains armed")
			helpers.assert_eq(timer:running(), true)
			helpers.assert_eq(stop_calls, 1)
			native_callback()
			helpers.assert_eq(calls, 0,
				"delivery while cleanup is refused must only retry the exact stop")
			helpers.assert_eq(stop_calls, 2)
			helpers.assert_eq(timer:running(), true)
			allow_stop = true
			helpers.assert_eq(engine.reset(), true,
				"the exact retained timer must be retried by the next reset")
			helpers.assert_eq(timer:running(), false)
			helpers.assert_eq(stop_calls, 3)
			native_callback()
			native_callback()
			helpers.assert_eq(calls, 0,
				"late and duplicate delivery after exact settlement must stay inert")
			helpers.assert_eq(stop_calls, 3,
				"late delivery may not reacquire or recancel the settled capability")
			engine.perform_check = real_perform
		end)
	end

	helpers.it("rejects a false inactivity start and acquires one distinct retry", function()
		local engine, _, hs_stub = load_fixture()
		engine.set_llm_enabled(true)
		local original_new = hs_stub.timer.new
		local timers = {}
		hs_stub.timer.new = function(delay, callback)
			local timer = original_new(delay, callback)
			timers[#timers + 1] = timer
			if #timers == 1 then
				timer.start = function(self)
					self.running = false
					return false
				end
			end
			return timer
		end

		helpers.assert_eq(engine.start_timer(), false,
			"a returned start call is not ownership while native state stays stopped")
		helpers.assert_eq(engine.start_timer_word_end(), true,
			"a later retry must acquire one distinct exact timer")
		hs_stub.timer.new = original_new
		helpers.assert_eq(#timers, 2)
		helpers.assert_true(timers[1] ~= timers[2])
		helpers.assert_eq(timers[2].running, true)
	end)

	helpers.it("contains and fences a mutate-then-throw inactivity start", function()
		local engine, _, hs_stub = load_fixture()
		engine.set_llm_enabled(true)
		local calls = 0
		local real_perform = engine.perform_check
		engine.perform_check = function() calls = calls + 1 end
		local original_new = hs_stub.timer.new
		local callback
		hs_stub.timer.new = function(delay, cb)
			callback = cb
			local timer = original_new(delay, cb)
			local start = timer.start
			timer.start = function(self)
				start(self)
				error("START_MUTATE_THROW")
			end
			return timer
		end

		local ok, result = pcall(engine.start_timer)
		hs_stub.timer.new = original_new
		helpers.assert_true(ok, "timer start failure must not escape into an eventtap")
		helpers.assert_eq(result, false)
		callback()
		callback()
		helpers.assert_eq(calls, 0,
			"late and duplicate delivery from a rejected start must stay inert")
		engine.perform_check = real_perform
	end)

	helpers.it("rejects synchronous inactivity delivery before start commit", function()
		local engine, _, hs_stub = load_fixture()
		engine.set_llm_enabled(true)
		local calls = 0
		local real_perform = engine.perform_check
		engine.perform_check = function() calls = calls + 1 end
		local original_new = hs_stub.timer.new
		hs_stub.timer.new = function(delay, callback)
			local timer = original_new(delay, callback)
			local start = timer.start
			timer.start = function(self)
				start(self)
				callback()
				return self
			end
			return timer
		end
		helpers.assert_eq(engine.start_timer(), false)
		hs_stub.timer.new = original_new
		helpers.assert_eq(calls, 0,
			"a callback delivered inside start may not perform prediction work")
		engine.perform_check = real_perform
	end)

	helpers.it("does not let a stopped predecessor consume its successor arm", function()
		local engine, _, hs_stub = load_fixture()
		engine.set_llm_enabled(true)
		local calls = 0
		local real_perform = engine.perform_check
		engine.perform_check = function() calls = calls + 1 end
		local original_new = hs_stub.timer.new
		local callbacks = {}
		hs_stub.timer.new = function(delay, callback)
			callbacks[#callbacks + 1] = callback
			return original_new(delay, callback)
		end

		helpers.assert_eq(engine.start_timer(), true)
		helpers.assert_eq(engine.stop_timer(), true)
		helpers.assert_eq(engine.start_timer(), true)
		hs_stub.timer.new = original_new
		callbacks[1]()
		callbacks[1]()
		helpers.assert_eq(calls, 0,
			"late and duplicate predecessor delivery must not borrow successor authority")
		callbacks[2]()
		callbacks[2]()
		helpers.assert_eq(calls, 1,
			"only the exact successor may perform one prediction check")
		engine.perform_check = real_perform
	end)

	helpers.it("contains a debounce callback throw through the module logger", function()
		local engine, _, hs_stub = load_fixture()
		engine.set_llm_enabled(true)
		local logger = package.loaded["infra.logger"]
		local original_error = logger.error
		local messages = {}
		logger.error = function(_, fmt, ...)
			local ok, message = pcall(string.format, tostring(fmt), ...)
			messages[#messages + 1] = ok and message or tostring(fmt)
		end
		local real_perform = engine.perform_check
		engine.perform_check = function() error("DEBOUNCE_CALLBACK_THROW") end
		helpers.assert_eq(engine.start_timer(0.02), true)
		local timer = hs_stub.timer.__timers[#hs_stub.timer.__timers]

		local callback_ok = pcall(timer.fire, timer)

		engine.perform_check = real_perform
		logger.error = original_error
		helpers.assert_true(callback_ok,
			"the debounce exception must not escape to Hammerspoon Console")
		local found = false
		for _, message in ipairs(messages) do
			if message:find("Inactivity debounce check raised", 1, true)
				and message:find("DEBOUNCE_CALLBACK_THROW", 1, true) then
				found = true
				break
			end
		end
		helpers.assert_true(found,
			"the production debounce boundary must report the contained exception")
	end)
end)
