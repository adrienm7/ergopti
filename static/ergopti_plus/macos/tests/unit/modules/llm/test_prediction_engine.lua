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




-- =====================================================
-- =====================================================
-- ======= 1/ Dependency stubs pre-registration =======
-- =====================================================
-- =====================================================

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
	set_llm_streaming       = function(_) end,
	cancel_streaming        = function() end,
}

-- Stub WarmupController — used as a module singleton, not instantiated.
package.loaded["modules.llm.warmup_controller"] = {
	schedule_warmup_with_retry = function(_reason) end,
	init                       = function(_cfg) end,
	start                      = function() end,
	stop                       = function() end,
}

-- Stub PromptBuilder — build() is called inside perform_check, not at load time.
package.loaded["modules.llm.prompt_builder"] = {
	new = function() return { build = function() return "", "" end } end,
}

-- Stub StreamingHandler — used as a module singleton.
package.loaded["modules.llm.streaming_handler"] = {
	init                 = function(_cfg) end,
	ngram_predict        = function(_buf) return {} end,
	build_callbacks      = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog         = function(_cfg) end,
	stop_watchdog        = function() end,
	reset_failure_count  = function() end,
	cancel_streaming     = function() end,
}

-- Stub AppFilter.
package.loaded["modules.llm.app_filter"] = {
	new = function() return { is_excluded = function() return false end } end,
}

-- Stub api_common (required inline at module level).
package.loaded["modules.llm.api_common"] = {
	MIN_CALL_INTERVAL_SEC = 0.5,
	get_retry_policy      = function() return 2, 0.18, 5 end,
}

-- Stub lib.i18n.
package.loaded["lib.i18n"] = {
	t = function(key) return key end,
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
}

-- Stub modules.keylogger — get_live_stats() and log_llm_dismissed() are both called.
package.loaded["modules.keylogger"] = {
	get_live_stats      = function() return { wpm = 0, wpm_short = 0 } end,
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




-- ===========================================
-- ===========================================
-- ======= 4/ Initial state accessors =======
-- ===========================================
-- ===========================================

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
		PE.set_llm_enabled(true)
		helpers.assert_eq(PE.get_llm_enabled(), true)
		PE.set_llm_enabled(false)
		helpers.assert_eq(PE.get_llm_enabled(), false)
	end)

	helpers.it("set_llm_temperature does not throw", function()
		PE.set_llm_temperature(0.7)
	end)

	helpers.it("set_llm_num_predictions does not throw", function()
		PE.set_llm_num_predictions(5)
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

	helpers.it("start_timer_word_end does not throw", function()
		PE.start_timer_word_end()
	end)
end)
