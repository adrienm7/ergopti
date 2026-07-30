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
package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

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
	cancel_streaming        = function() end,
	-- Dispatch-path surface (exercised by the perform_check regression in §8).
	is_backend_ready        = function() return true end,
	get_active_profile      = function() return { label = "Test profile" } end,
	fetch_llm_prediction    = function(...) end,
}

-- Stub WarmupController — used as a module singleton, not instantiated.
package.loaded["modules.llm.warmup_controller"] = {
	schedule_warmup_with_retry = function(_reason) end,
	init                       = function(_cfg) end,
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
package.loaded["modules.llm.prompt_builder"] = {
	build = function(_buf, _cfg, _last_sig, _force)
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
	init                 = function(_cfg) end,
	build_callbacks      = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog         = function(_cfg) end,
	stop_watchdog        = function() end,
	reset_failure_count  = function() end,
	cancel_streaming     = function() end,
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
package.loaded["lib.i18n"] = {
	t   = function(key) return key end,
	get = function(key) return key end,
}

-- Stub lib.keycodes.
package.loaded["lib.keycodes"] = {
	F16_LLM_CHAIN_SIGNAL = 106,
}

-- Stub ui.tooltip — set_navigate_callback and set_enter_validates are called
-- at module load time (lines 879-881 of prediction_engine.lua).
package.loaded["ui.tooltip"] = {
	set_navigate_callback = function(_) end,
	set_enter_validates   = function(_) end,
	set_chain_start       = function(_) end,
	mark_chain_complete   = function() end,
	get_current_index     = function() return nil end,
	navigate              = function(_) end,
	show                  = function() end,
	hide                  = function() end,
	-- Dispatch-path surface (exercised by §8).
	set_llm_timeout       = function(_) end,
	reset_llm_timer       = function() end,
	show_loading          = function(...) end,
	show_predictions      = function(...) end,
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
		package.loaded["ui.tooltip"].hide_forced = function() tt_hidden_forced = true end
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
	helpers.it("set_llm_max_words / set_llm_min_words coerce a wrong type to a number", function()
		PE.set_llm_max_words("five")
		local mx = hs.settings.get("llm_max_words")
		helpers.assert_eq(type(mx), "number")
		-- Exactly the comparison that crashed on the raw string.
		helpers.assert_true(pcall(function() return mx > 0 end))

		PE.set_llm_min_words("seven")
		helpers.assert_eq(type(hs.settings.get("llm_min_words")), "number")

		-- A genuine numeric string is still accepted (coerced).
		PE.set_llm_max_words("12")
		helpers.assert_eq(hs.settings.get("llm_max_words"), 12)
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
		local ok = pcall(function() PE.start_timer(10.0) end)
		helpers.assert_true(ok)
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
		PE.init({ buffer = "hello wor", mappings = {}, DELAYS = { llm_prediction = 0 } })

		-- force_trigger = true bypasses the freshness and backend-floor guards so
		-- the call goes straight to dispatch.
		local ok, err = pcall(function() PE.perform_check(true) end)

		core.fetch_llm_prediction = prev_fetch
		PE.set_llm_enabled(false)

		helpers.assert_true(ok, "perform_check must not throw on the dispatch path: " .. tostring(err))
		helpers.assert_true(dispatched, "perform_check must dispatch fetch_llm_prediction when the backend is ready")
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
		tt.hide        = function() calls[#calls + 1] = "hide" end
		tt.hide_forced = function() calls[#calls + 1] = "hide_forced" end

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
