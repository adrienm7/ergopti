--- tests/unit/modules/llm/test_prediction_engine.lua

--- ==============================================================================
--- MODULE: llm.prediction_engine Unit Tests
--- DESCRIPTION:
--- Tests the pure, side-effect-free surface of the prediction engine: the
--- normalize_mods helper, configuration setters, and the initial state accessors.
--- The LLM pipeline itself (perform_check, HTTP calls, tooltip rendering) requires
--- a live macOS + MLX/Ollama environment and is deferred to integration testing.
---
--- FEATURES & RATIONALE:
--- 1. Dependency Isolation: Heavy dependencies (modules.llm, modules.keylogger,
---    ui.tooltip, WarmupController, etc.) are stubbed via package.loaded before
---    the engine loads.
--- 2. Pure-Function Coverage: normalize_mods, is_visible, is_chain_pending,
---    get_predictions, and all set_* setters are exercised without any OS call.
--- 3. Loader Safety: Verifies that the module can load under the standard hs stub
---    environment after all dependencies are in place.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ====================================================
-- ====================================================
-- ======= 1/ Dependency stubs pre-registration =======
-- ====================================================
-- ====================================================

-- Reset the hs stub and package cache for a clean load.
package.loaded["modules.llm.prediction_engine"] = nil
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

-- Stub modules.llm (core_llm) — only the surface prediction_engine uses at
-- module-load time and in setters is needed.
package.loaded["modules.llm"] = {
	DEFAULT_STATE        = {
		llm_enabled            = false,
		llm_temperature        = 0.1,
		llm_context_length     = 4000,
		llm_min_words          = 2,
		llm_max_words          = 0,
		llm_num_predictions    = 3,
		llm_pred_indent        = 0,
		llm_val_modifiers      = { "alt" },
		llm_nav_modifiers      = { "ctrl" },
		llm_show_info_bar      = true,
		llm_sequential_mode    = false,
		llm_debounce           = 0.3,
		llm_auto_raise_temp    = false,
		llm_streaming          = false,
		llm_streaming_multi    = false,
		llm_instant_on_word_end = false,
	},
	get_current_model       = function() return "llama3" end,
	get_backend             = function() return "ollama" end,
	set_llm_model_mlx       = function(_) end,
	set_llm_model_ollama    = function(_) end,
	set_runtime_llm_enabled = function(_) end,
	set_llm_streaming       = function(_) end,
	cancel_streaming        = function() return true end,
	-- Dispatch-path surface (exercised by the perform_check regression in §8).
	is_backend_ready        = function() return true end,
	get_active_profile      = function() return { label = "Test profile" } end,
	fetch_llm_prediction    = function(...) end,
}

-- Stub WarmupController — used as a module singleton, not instantiated.
package.loaded["modules.llm.warmup_controller"] = {
	schedule_warmup_with_retry = function(_reason) end,
	init                       = function(_cfg) return true end,
	start                      = function() end,
	stop                       = function() end,
}

local runtime_llm_enabled_calls = {}
package.loaded["modules.llm"].set_runtime_llm_enabled = function(enabled)
	runtime_llm_enabled_calls[#runtime_llm_enabled_calls + 1] = enabled
end

local warmup_schedule_reasons = {}
package.loaded["modules.llm.warmup_controller"].schedule_warmup_with_retry = function(reason)
	warmup_schedule_reasons[#warmup_schedule_reasons + 1] = reason
end

-- Stub PromptBuilder — build() (the real export shape) is called inside
-- perform_check. It returns (params, skip_reason, signature); a non-nil params
-- table drives the dispatch path exercised by §8.
local last_prompt_buffer = nil
package.loaded["modules.llm.prompt_builder"] = {
	build = function(buf, _cfg, _last_sig, _force)
		last_prompt_buffer = buf
		return {
			tail            = "wor",
			context_buffer  = "hello wor",
			max_tokens      = 64,
			req_temperature = 0.1,
			num_preds       = 3,
		}, nil, "sig-1"
	end,
}

-- Stub StreamingHandler — used as a module singleton. NOTE: intentionally mirrors
-- the REAL production surface, which has NO ngram_predict. A previous stub
-- defined ngram_predict here, masking the dangling prediction_engine call that
-- crashed every live request (the §8 regression locks this down).
package.loaded["modules.llm.streaming_handler"] = {
	init                 = function(_cfg) return true end,
	build_callbacks      = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog         = function(_cfg) return true end,
	stop_watchdog        = function() return true end,
	reset_failure_count  = function() end,
	cancel_streaming     = function() return true end,
}

-- Stub AppFilter — the real export is is_blocked(state, apps, url_filter, secure_filter).
package.loaded["modules.llm.app_filter"] = {
	is_blocked = function(_state, _apps, _url, _secure) return false end,
}

-- Stub api_common (required inline at module level). get_rate_limit_min_interval_s
-- is the real export the floor check calls; 0 means "never defer" for tests.
package.loaded["modules.llm.api_common"] = {
	MIN_CALL_INTERVAL_SEC = 0.5,
	get_retry_policy      = function() return 2, 0.18, 5 end,
	get_rate_limit_min_interval_s = function(_backend) return 0 end,
}

-- Stub lib.i18n — perform_check uses i18n.get() for the loading label.
package.loaded["infra.i18n"] = {
	t   = function(key) return key end,
	get = function(key) return key end,
}

-- Stub lib.keycodes.
package.loaded["infra.keycodes"] = {
	F16_LLM_CHAIN_SIGNAL = 106,
}

-- Stub ui.tooltip — set_navigate_callback and set_enter_validates are called
-- at module load time (lines 879-881 of prediction_engine.lua).
package.loaded["ui.tooltip"] = {
	set_navigate_callback = function(_) end,
	set_enter_validates   = function(_) end,
	set_chain_start       = function(_) return true end,
	mark_chain_complete   = function() return true end,
	get_current_index     = function() return nil end,
	navigate              = function(_) end,
	show                  = function() end,
	hide                  = function() return true end,
	-- Dispatch-path surface (exercised by §8).
	set_llm_timeout       = function(_) end,
	reset_llm_timer       = function() return true end,
	show_loading          = function(...) return true end,
	show_predictions      = function(...) return true end,
	tint                  = function(_) return nil end,
}

-- Stub modules.keylogger — get_live_stats() returns wpm_physical (the field the
-- adaptive debounce reads); log_llm_dismissed() is called on reset.
package.loaded["modules.keylogger"] = {
	get_live_stats      = function() return { wpm_physical = 0 } end,
	log_llm_dismissed   = function(_, _preds) end,
}

-- Now load the prediction engine with all stubs registered.
local PE = require("modules.llm.prediction_engine")

--- Loads the production bridge against this file's production prediction engine.
--- Unrelated keymap dependencies are inert because this fixture invokes only the
--- direct configuration-forwarding surface.
--- @return table bridge Fresh production bridge instance.
local function load_real_setting_bridge()
	local noop = function() end
	local replacements = {
		["modules.keymap.utils"] = {},
		["adapters.event_provenance"] = {STATUS_UNREADABLE = "unreadable"},
		["adapters.synthetic_input"] = {current_action_epoch = function() return 0 end},
		["infra.text_utils"] = {},
		["infra.keycodes"] = {
			ESCAPE = 53,
			RETURN = 36,
			F16_LLM_CHAIN_SIGNAL = 106,
			to_name = function() return "f16" end,
		},
		["modules.keylogger"] = {},
		["ui.tooltip"] = {},
		["modules.keymap.registry"] = {},
		["modules.hotstrings.hotstrings_config"] = {},
		["modules.keymap.expander"] = {},
		["adapters.timer_scheduler"] = {after = noop},
		["infra.manifest_reader"] = {},
		["modules.diagnostics.hid_diagnostic_mailbox"] = {},
		["modules.llm.prediction_engine"] = PE,
	}
	local saved = {}
	for name, replacement in pairs(replacements) do
		saved[name] = package.loaded[name]
		package.loaded[name] = replacement
	end
	local saved_bridge = package.loaded["modules.keymap.llm_bridge"]
	package.loaded["modules.keymap.llm_bridge"] = nil
	local ok, bridge_or_error = xpcall(function()
		return require("modules.keymap.llm_bridge")
	end, debug.traceback)
	for name in pairs(replacements) do package.loaded[name] = saved[name] end
	package.loaded["modules.keymap.llm_bridge"] = saved_bridge
	if not ok then error(bridge_or_error, 0) end
	return bridge_or_error
end




-- ====================================
-- ====================================
-- ======= 2/ Module surface ===========
-- ====================================
-- ====================================

helpers.describe("prediction_engine — module surface", function()
	helpers.it("loads without error", function()
		helpers.assert_true(type(PE) == "table", "module must return a table")
	end)

	helpers.it("exports required public functions", function()
		for _, fn in ipairs({
			"init", "reset", "consume", "arm_chain",
			"perform_check", "stop_timer", "start_timer", "start_timer_word_end",
			"handle_chain_signal", "navigate",
			"is_visible", "is_chain_pending", "get_predictions", "get_current_index",
			"normalize_mods", "get_navigation_mods", "get_validation_mods",
			"get_llm_runtime_setting",
		}) do
			helpers.assert_eq(type(PE[fn]), "function", "missing export: " .. fn)
		end
	end)

	helpers.it("exports KEYCODE_LLM_CHAIN constant", function()
		helpers.assert_eq(type(PE.KEYCODE_LLM_CHAIN), "number")
	end)

	helpers.it("exports CHAIN_FALLBACK_SEC constant", function()
		helpers.assert_eq(type(PE.CHAIN_FALLBACK_SEC), "number")
	end)

	helpers.it("calls tooltip.hide_forced immediately on reset (e.g. after prediction apply)", function()
		local tt_hidden_forced = false
		local old_hide_forced = package.loaded["ui.tooltip"].hide_forced
		package.loaded["ui.tooltip"].hide_forced = function() tt_hidden_forced = true; return true end
		PE.reset()
		helpers.assert_true(tt_hidden_forced, "tooltip.hide_forced must be called on reset")
		package.loaded["ui.tooltip"].hide_forced = old_hide_forced
	end)
end)




-- =============================================
-- =============================================
-- ======= 3/ normalize_mods pure logic ========
-- =============================================
-- =============================================

helpers.describe("prediction_engine — normalize_mods", function()
	helpers.it("wraps a string in a single-element table", function()
		local result = PE.normalize_mods("alt")
		helpers.assert_eq(type(result), "table")
		helpers.assert_eq(#result, 1)
		helpers.assert_eq(result[1], "alt")
	end)

	helpers.it("returns a table unchanged", function()
		local mods = { "cmd", "shift" }
		local result = PE.normalize_mods(mods)
		helpers.assert_eq(result, mods)
	end)

	helpers.it("returns empty table for nil", function()
		local result = PE.normalize_mods(nil)
		helpers.assert_eq(type(result), "table")
		helpers.assert_eq(#result, 0)
	end)

	helpers.it("returns empty table for false", function()
		local result = PE.normalize_mods(false)
		helpers.assert_eq(type(result), "table")
		helpers.assert_eq(#result, 0)
	end)

	helpers.it("handles multi-mod table", function()
		local result = PE.normalize_mods({ "cmd", "alt", "shift" })
		helpers.assert_eq(#result, 3)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 4/ Initial state accessors =======
-- ==========================================
-- ==========================================

helpers.describe("prediction_engine — initial state", function()
	helpers.it("is_visible returns false initially", function()
		helpers.assert_eq(PE.is_visible(), false)
	end)

	helpers.it("is_chain_pending returns false initially", function()
		helpers.assert_eq(PE.is_chain_pending(), false)
	end)

	helpers.it("get_predictions returns an empty table initially", function()
		local preds = PE.get_predictions()
		helpers.assert_eq(type(preds), "table")
		helpers.assert_eq(#preds, 0)
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 5/ Configuration setter smoke ========
-- ==============================================
-- ==============================================

helpers.describe("prediction_engine — configuration setters", function()
	helpers.it("set_llm_enabled accepts boolean", function()
		runtime_llm_enabled_calls = {}
		warmup_schedule_reasons = {}
		PE.set_llm_enabled(true)
		helpers.assert_eq(PE.get_llm_enabled(), true)
		helpers.assert_eq(runtime_llm_enabled_calls[#runtime_llm_enabled_calls], true)
		helpers.assert_eq(warmup_schedule_reasons[#warmup_schedule_reasons], "set_llm_enabled")
		PE.set_llm_enabled(false)
		helpers.assert_eq(PE.get_llm_enabled(), false)
		helpers.assert_eq(runtime_llm_enabled_calls[#runtime_llm_enabled_calls], false)
	end)

	helpers.it("set_llm_temperature does not throw", function()
		PE.set_llm_temperature(0.7)
	end)

	helpers.it("set_llm_num_predictions does not throw", function()
		PE.set_llm_num_predictions(5)
	end)

	-- F-M10: a wrong-typed config.toml / plist value (e.g. max_words = "five")
	-- reached `<=`/`>` in the prompt_builder and `> 0` in the menu, crashing both.
	-- The setters now coerce + fail closed to the numeric default.
	helpers.it("min/max setters coerce runtime values without publishing hs.settings", function()
		local original_set = hs.settings.set
		local writes = {}
		hs.settings.set = function(key, value)
			writes[#writes + 1] = {key = key, value = value}
			return original_set(key, value)
		end
		local ok, values_or_error = xpcall(function()
			PE.set_llm_max_words("five")
			local max_found, mx = PE.get_llm_runtime_setting("llm_max_words")

			PE.set_llm_min_words("seven")
			local min_found, mn = PE.get_llm_runtime_setting("llm_min_words")

			-- A genuine numeric string is still accepted (coerced).
			PE.set_llm_max_words("12")
			local numeric_found, numeric_max = PE.get_llm_runtime_setting("llm_max_words")
			return {
				max_found = max_found,
				max_value = mx,
				min_found = min_found,
				min_value = mn,
				numeric_found = numeric_found,
				numeric_max = numeric_max,
			}
		end, debug.traceback)
		hs.settings.set = original_set
		if not ok then error(values_or_error, 0) end

		local values = values_or_error
		helpers.assert_eq(values.max_found, true)
		local mx = values.max_value
		helpers.assert_eq(type(mx), "number")
		-- Exactly the comparison that crashed on the raw string.
		-- The comparison crashed pre-fix on a string. Asserting the TYPE is what the
		-- fix guarantees, and it is stronger than "this one comparison did not raise".
		helpers.assert_eq(type(mx), "number", "a coerced max must be a number, not a string")
		helpers.assert_eq(values.min_found, true)
		helpers.assert_eq(type(values.min_value), "number")
		helpers.assert_eq(values.numeric_found, true)
		helpers.assert_eq(values.numeric_max, 12)
		helpers.assert_eq(writes, {},
			"SettingsManager is the sole native plist publisher for min/max words")
	end)

	helpers.it("runtime getter observes every engine-owned transactional setting", function()
		for _, case in ipairs({
			{key = "llm_debounce", setter = "set_llm_debounce", value = 0.42},
			{key = "llm_max_words", setter = "set_llm_max_words", value = 21},
			{key = "llm_min_words", setter = "set_llm_min_words", value = 5},
			{key = "llm_temperature", setter = "set_llm_temperature", value = 0.64},
			{key = "llm_context_length", setter = "set_llm_context_length", value = 812},
			{key = "llm_num_predictions", setter = "set_llm_num_predictions", value = 4},
			{key = "llm_show_info_bar", setter = "set_llm_show_info_bar", value = false},
			{key = "llm_sequential_mode", setter = "set_llm_sequential_mode", value = true},
			{key = "llm_auto_raise_temp", setter = "set_llm_auto_raise_temp", value = true},
			{key = "llm_streaming", setter = "set_llm_streaming", value = true},
			{key = "llm_streaming_multi", setter = "set_llm_streaming_multi", value = true},
			{key = "llm_pred_indent", setter = "set_llm_pred_indent", value = 2},
			{key = "llm_nav_modifiers", setter = "set_llm_nav_modifiers", value = {"ctrl"}},
			{key = "llm_val_modifiers", setter = "set_llm_val_modifiers", value = {"shift"}},
			{key = "llm_instant_on_word_end", setter = "set_llm_instant_on_word_end", value = true},
			{key = "llm_url_bar_filter_enabled", setter = "set_llm_url_bar_filter_enabled", value = false},
			{key = "llm_secure_field_filter_enabled", setter = "set_llm_secure_field_filter_enabled", value = false},
			{key = "llm_disabled_apps", setter = "set_llm_disabled_apps", value = {{name = "Terminal"}}},
		}) do
			PE[case.setter](case.value)
			local found, value = PE.get_llm_runtime_setting(case.key)
			helpers.assert_eq(found, true, "runtime owner missing " .. case.key)
			helpers.assert_eq(value, case.value, "runtime owner returned stale " .. case.key)
		end
		local found, value = PE.get_llm_runtime_setting("not_a_setting")
		helpers.assert_eq(found, false)
		helpers.assert_nil(value)
	end)

	helpers.it("real bridge propagates the real engine debounce refusal and throw", function()
		local bridge = load_real_setting_bridge()
		local inactivity_timer = nil
		for _, timer in ipairs(hs.timer.__timers) do
			if type(timer.setDelay) == "function" then inactivity_timer = timer end
		end
		helpers.assert_true(inactivity_timer ~= nil,
			"the production engine must own its canonical delayed timer")

		local old_found, old_debounce = PE.get_llm_runtime_setting("llm_debounce")
		helpers.assert_eq(old_found, true)
		local original_stop = inactivity_timer.stop
		local original_running = inactivity_timer.running
		inactivity_timer.running = true
		inactivity_timer.stop = function(self) return self end
		local call_ok, refused = pcall(bridge.set_llm_debounce, 0.73)
		inactivity_timer.stop = original_stop
		inactivity_timer.running = false
		local restored = PE.set_llm_debounce(old_debounce)
		inactivity_timer.running = original_running
		helpers.assert_true(call_ok)
		helpers.assert_eq(refused, false,
			"the bridge must expose the engine timer's exact false refusal")
		helpers.assert_eq(restored, true)

		local original_temperature = PE.set_llm_temperature
		PE.set_llm_temperature = function() error("real engine boundary exploded") end
		local throw_ok, throw_error = pcall(bridge.set_llm_temperature, 0.8)
		PE.set_llm_temperature = original_temperature
		helpers.assert_eq(throw_ok, false)
		helpers.assert_true(tostring(throw_error):find(
			"real engine boundary exploded", 1, true) ~= nil)
	end)

	helpers.it("set_llm_debounce recreates the timer without throwing", function()
		PE.set_llm_debounce(0.5)
	end)

	helpers.it("set_llm_val_modifiers normalizes a string", function()
		PE.set_llm_val_modifiers("cmd")
		local mods = PE.get_validation_mods()
		helpers.assert_eq(type(mods), "table")
	end)

	helpers.it("set_llm_nav_modifiers normalizes a table", function()
		PE.set_llm_nav_modifiers({ "ctrl", "shift" })
		local mods = PE.get_navigation_mods()
		helpers.assert_eq(type(mods), "table")
		helpers.assert_eq(#mods, 2)
	end)

	helpers.it("set_llm_disabled_apps does not throw", function()
		PE.set_llm_disabled_apps({ "com.apple.Terminal" })
	end)

	helpers.it("set_llm_streaming accepts boolean", function()
		PE.set_llm_streaming(true)
		PE.set_llm_streaming(false)
	end)

	helpers.it("set_preview_ai_enabled accepts boolean", function()
		PE.set_preview_ai_enabled(true)
		PE.set_preview_ai_enabled(false)
		PE.set_preview_ai_enabled(true)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 6/ consume() edge cases ==========
-- ==========================================
-- ==========================================

helpers.describe("prediction_engine — consume()", function()
	helpers.it("consume(1) returns nil pair when no predictions loaded", function()
		local pred, all = PE.consume(1)
		helpers.assert_nil(pred)
		-- When index is invalid, all_preds is also nil per the implementation contract.
		helpers.assert_nil(all)
	end)

	helpers.it("consume(99) does not throw", function()
		PE.consume(99)
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 7/ stop_timer safety =============
-- ==========================================
-- ==========================================

helpers.describe("prediction_engine — timer safety", function()
	helpers.it("stop_timer does not throw when no request is in flight", function()
		PE.stop_timer()
	end)

	helpers.it("start_timer does not throw", function()
		PE.start_timer()
	end)

	helpers.it("start_timer with override does not throw (regression for timer replacement)", function()
		-- Called directly: a raise fails with the real error.
		PE.start_timer(10.0)
		helpers.assert_eq(type(PE.start_timer), "function", "and must leave the engine callable")
	end)

	helpers.it("start_timer_word_end does not throw", function()
		PE.start_timer_word_end()
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 8/ perform_check dispatch (no-prediction regression) ====
-- =================================================================
-- =================================================================
-- Regression for the silent "green dot but no prediction" bug: perform_check
-- called StreamingHandler.ngram_predict(buffer), a function the production
-- StreamingHandler never implemented — only this test file's stub provided it.
-- The dangling call threw inside the hs.timer.delayed callback (Hammerspoon
-- swallowed the error to its Console), so every request died after the prompt
-- builder accepted the signature and BEFORE the backend dispatch — no prediction
-- ever appeared even when the backend was ready.
--
-- The stubs above now mirror the real StreamingHandler surface (no ngram_predict),
-- so this test reproduces the crash before the fix and passes after it: with a
-- ready backend and a fresh buffer, perform_check MUST reach
-- core_llm.fetch_llm_prediction.

helpers.describe("prediction_engine — perform_check dispatch", function()
	helpers.it("dispatches a backend request when ready (no dependency on a removed ngram_predict)", function()
		local core = package.loaded["modules.llm"]
		local dispatched = false
		local prev_fetch = core.fetch_llm_prediction
		core.fetch_llm_prediction = function(...) dispatched = true end

		-- Guard: the real StreamingHandler exposes no ngram_predict — calling one
		-- would be the exact bug this test exists to catch.
		helpers.assert_nil(
			package.loaded["modules.llm.streaming_handler"].ngram_predict,
			"StreamingHandler must not require an ngram_predict helper"
		)

		PE.set_llm_enabled(true)
		PE.init({
			buffer = "stale cursor text",
			llm_buffer = "hello wor",
			mappings = {},
			DELAYS = { llm_prediction = 0 },
		})

		-- force_trigger = true bypasses the freshness and backend-floor guards so
		-- the call goes straight to dispatch.
		local ok, err = pcall(function() PE.perform_check(true) end)

		core.fetch_llm_prediction = prev_fetch
		PE.set_llm_enabled(false)

		helpers.assert_true(ok, "perform_check must not throw on the dispatch path: " .. tostring(err))
		helpers.assert_true(dispatched, "perform_check must dispatch fetch_llm_prediction when the backend is ready")
		helpers.assert_eq(last_prompt_buffer, "hello wor",
			"prompt construction must read only the independent LLM context")
	end)

	helpers.it("(no-model-runtime) ready MLX cannot render, fetch, or warm without an active model", function()
		local core = package.loaded["modules.llm"]
		local tooltip = package.loaded["ui.tooltip"]
		local warmup = package.loaded["modules.llm.warmup_controller"]
		local previous_model = core.get_current_model
		local previous_backend = core.get_backend
		local previous_ready = core.is_backend_ready
		local previous_fetch = core.fetch_llm_prediction
		local previous_show_loading = tooltip.show_loading
		local previous_show_predictions = tooltip.show_predictions
		local previous_schedule = warmup.schedule_warmup_with_retry
		local shows, fetches, warmups = 0, 0, 0

		core.get_current_model = function() return "" end
		core.get_backend = function() return "mlx" end
		core.is_backend_ready = function() return true end
		core.fetch_llm_prediction = function() fetches = fetches + 1 end
		tooltip.show_loading = function() shows = shows + 1; return true end
		tooltip.show_predictions = function() shows = shows + 1; return true end
		warmup.schedule_warmup_with_retry = function() warmups = warmups + 1 end

		local ok, err = xpcall(function()
			PE.set_llm_enabled(true)
			warmups = 0
			PE.set_llm_model("")
			PE.init({
				buffer = "hello wor",
				llm_buffer = "hello wor",
				mappings = {},
				DELAYS = { llm_prediction = 0 },
			})
			PE.perform_check(true)
			helpers.assert_eq(shows, 0,
				"a stale MLX ready flag must not paint a loading or prediction surface")
			helpers.assert_eq(fetches, 0)
			helpers.assert_eq(warmups, 0,
				"No Model is a disabled identity, not an empty model to warm")
		end, debug.traceback)

		core.get_current_model = previous_model
		core.get_backend = previous_backend
		core.is_backend_ready = previous_ready
		core.fetch_llm_prediction = previous_fetch
		tooltip.show_loading = previous_show_loading
		tooltip.show_predictions = previous_show_predictions
		warmup.schedule_warmup_with_retry = previous_schedule
		PE.set_llm_enabled(false)
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("prediction_engine — reset stays off the input I/O path", function()
	helpers.it("clears visible state synchronously but defers dismissal persistence", function()
		local core = package.loaded["modules.llm"]
		local streaming = package.loaded["modules.llm.streaming_handler"]
		local keylogger = package.loaded["modules.keylogger"]
		local scheduler = require("adapters.timer_scheduler")
		local previous_fetch = core.fetch_llm_prediction
		local previous_build = streaming.build_callbacks
		local previous_log = keylogger.log_llm_dismissed
		local previous_after = scheduler.after
		local scheduled = {}
		local dismissal_calls = 0

		scheduler.after = function(_, callback)
			scheduled[#scheduled + 1] = callback
			return { timer = {}, fired = false }
		end
		keylogger.log_llm_dismissed = function()
			dismissal_calls = dismissal_calls + 1
		end
		streaming.build_callbacks = function(config)
			local function success(predictions)
				config.pending_predictions_ref.value = predictions
				config.predictions_visible_ref.value = true
			end
			return nil, success, function() end
		end
		core.fetch_llm_prediction = function(...)
			local on_success = select(7, ...)
			on_success({ { to_type = " completion", deletes = 0 } }, 1, true, false)
		end

		local ok, err = xpcall(function()
			PE.set_llm_enabled(true)
			PE.init({
				buffer = "hello wor",
				llm_buffer = "hello wor",
				mappings = {},
				DELAYS = { llm_prediction = 0 },
			})
			PE.perform_check(true)
			helpers.assert_true(PE.is_visible())

			PE.reset()
			helpers.assert_true(not PE.is_visible(),
				"stale predictions must be invalid immediately")
			helpers.assert_eq(dismissal_calls, 0,
				"reset must not persist telemetry in the caller's eventtap stack")
			helpers.assert_true(#scheduled > 0,
				"dismissal persistence must have a deferred continuation")
			for _, callback in ipairs(scheduled) do callback() end
			helpers.assert_eq(dismissal_calls, 1)
		end, debug.traceback)

		core.fetch_llm_prediction = previous_fetch
		streaming.build_callbacks = previous_build
		keylogger.log_llm_dismissed = previous_log
		scheduler.after = previous_after
		PE.set_llm_enabled(false)
		if not ok then error(err, 0) end
	end)
end)





-- ====================================================================
-- ====================================================================
-- ======= 9/ Disabling the AI bubble is a teardown, not a hide =======
-- ====================================================================
-- ====================================================================

--- set_preview_ai_enabled(false) used to call a bare tooltip.hide(). That clears
--- the canvas and nothing else: predictions_visible stayed true, the pending set
--- stayed populated, and neither request counter moved — so an in-flight stream
--- still passed its own generation check and repainted the bubble the user had
--- just switched off. The teardown contract already existed in M.reset(); the
--- disable path simply did not use it.
helpers.describe("prediction_engine: turning the AI preview off tears the state down", function()

	helpers.it("hides forcibly rather than with the soft hide the dismiss contract forbids", function()
		local calls = {}
		local tt = package.loaded["ui.tooltip"]
		local old_hide, old_forced = tt.hide, tt.hide_forced
		tt.hide        = function() calls[#calls + 1] = "hide"; return true end
		tt.hide_forced = function() calls[#calls + 1] = "hide_forced"; return true end

		PE.set_preview_ai_enabled(false)

		tt.hide, tt.hide_forced = old_hide, old_forced

		local saw_forced = false
		for _, c in ipairs(calls) do if c == "hide_forced" then saw_forced = true end end
		helpers.assert_true(saw_forced,
			"a soft hide clears the canvas without firing the cancel contract, so the engine "
			.. "still believes a prediction is on screen and an in-flight stream repaints it")
	end)

	helpers.it("leaves no prediction believed visible", function()
		PE.set_preview_ai_enabled(false)
		helpers.assert_eq(PE.is_visible(), false,
			"predictions_visible must be cleared by the disable, otherwise navigation and "
			.. "validation keystrokes keep being captured for a bubble that is gone")
	end)

	helpers.it("re-enabling does not resurrect the torn-down state", function()
		PE.set_preview_ai_enabled(false)
		PE.set_preview_ai_enabled(true)
		helpers.assert_eq(PE.is_visible(), false,
			"turning the preview back on must not make a previously pending set visible again")
	end)

end)
