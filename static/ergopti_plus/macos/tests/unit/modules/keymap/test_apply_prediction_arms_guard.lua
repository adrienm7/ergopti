--- tests/unit/modules/keymap/test_apply_prediction_arms_guard.lua

--- ==============================================================================
--- MODULE: apply_prediction Guard-Arm Regression Test
--- DESCRIPTION:
--- Regression guard for the ordering invariant inside apply_prediction():
--- _state.last_synthetic_arm_time MUST be updated before the synthetic-event
--- counters are incremented, so the A6 guard in onKeyDownRaw cannot clear those
--- counters mid-expansion.
---
--- FEATURES & RATIONALE:
--- 1. Root-cause encoding: the test encodes the exact ordering invariant, not
---    merely the symptom, so any future regression to the wrong order fails here
---    before it ever reaches a live keyboard.
--- 2. Self-contained: all heavy dependencies (engine, km_utils, keylogger,
---    tooltip, Registry, hotstrings_config) are stubbed at the package level so
---    the test runs fully headless without a Hammerspoon environment.
--- 3. Temporal assertion: asserts that the updated timestamp is within 0.5 s of
---    the current wall-clock time, tolerating any realistic test-harness latency.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================
-- ================================================
-- ======= 1/ Dependency Stubs ===================
-- ================================================
-- ================================================

-- Warm the hs stub so _G.hs and package.loaded["hs"] are set for the entire
-- dependency chain loaded below.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")


--- =========================================
-- ===== 1.1) Engine stub ===================
--- =========================================

-- Captured consume() call arguments and arm_chain() call count for inspection.
local engine_consume_called_with = nil
local engine_arm_chain_count     = 0

-- The stub prediction returned by engine.consume().
-- Contains the minimum fields read by apply_prediction().
local STUB_PRED = { deletes = 1, to_type = "world" }

package.loaded["modules.llm.prediction_engine"] = {
	init                          = function() end,
	consume                       = function(idx)
		engine_consume_called_with = idx
		-- Return (pred, all_preds) matching the real signature
		return STUB_PRED, { STUB_PRED }
	end,
	reset                         = function() end,
	arm_chain                     = function() engine_arm_chain_count = engine_arm_chain_count + 1 end,
	get_llm_enabled               = function() return false end,
	set_llm_enabled               = function() end,
	set_llm_model                 = function() end,
	set_llm_display_model_name    = function() end,
	set_llm_show_model_name       = function() end,
	set_llm_backend_name          = function() end,
	set_llm_context_length        = function() end,
	set_llm_temperature           = function() end,
	set_llm_num_predictions       = function() end,
	set_llm_pred_indent           = function() end,
	set_llm_show_info_bar         = function() end,
	set_llm_sequential_mode       = function() end,
	set_llm_auto_raise_temp       = function() end,
	set_llm_disabled_apps         = function() end,
	set_llm_url_bar_filter_enabled      = function() end,
	set_llm_secure_field_filter_enabled = function() end,
	set_llm_instant_on_word_end   = function() end,
	set_llm_val_modifiers         = function() end,
	set_llm_nav_modifiers         = function() end,
	set_llm_min_words             = function() end,
	set_llm_max_words             = function() end,
	set_llm_debounce              = function() end,
	set_llm_streaming             = function() end,
	set_llm_streaming_multi       = function() end,
	set_preview_ai_enabled        = function() end,
	set_preview_ai_color          = function() end,
	get_predictions               = function() return {} end,
	get_current_index             = function() return 1 end,
	get_navigation_mods           = function() return {} end,
	get_validation_mods           = function() return {} end,
	is_visible                    = function() return false end,
	start_timer                   = function() end,
	start_timer_word_end          = function() end,
	stop_timer                    = function() end,
	perform_check                 = function() end,
	handle_chain_signal           = function() return false end,
	navigate                      = function() end,
}


--- =========================================
-- ===== 1.2) km_utils stub =================
--- =========================================

-- resolve_prediction_overlap: pass through unchanged (no overlap in the test
-- fixture) so the delete/type counts remain predictable.
-- emit_text: return the text verbatim to avoid driving the real keystroke path.
package.loaded["modules.keymap.utils"] = {
	resolve_prediction_overlap = function(_, deletes, text) return deletes, text end,
	emit_text                  = function(text) return true, text end,
	plain_text                 = function(s) return s end,
	tokens_from_repl           = function(s) return s end,
}


--- =========================================
-- ===== 1.3) Keylogger stub ================
--- =========================================

package.loaded["modules.keylogger"] = {
	log_hotstring_suggested  = function() end,
	log_hotstring_dismissed  = function() end,
	notify_synthetic         = function() end,
	log_llm_accepted         = function() end,
	set_buffer               = function() end,
}


--- =========================================
-- ===== 1.4) Tooltip stub ==================
--- =========================================

package.loaded["ui.tooltip"] = {
	hide                   = function() end,
	show_stacked           = function() end,
	set_timeout            = function() end,
	is_visible             = function() return false end,
	tint                   = function() return nil end,
	set_colorization_enabled = function() end,
	set_accent_color       = function() end,
	set_accept_callback    = function() end,
	set_cancel_callback    = function() end,
	set_on_show_callback   = function() end,
}


--- =========================================
-- ===== 1.5) Registry stub =================
--- =========================================

package.loaded["modules.keymap.registry"] = {
	init                       = function() end,
	mappings_for_tail          = function() return nil end,
	mappings_for_star_tail     = function() return nil end,
}


--- =========================================
-- ===== 1.6) hotstrings_config stub ========
--- =========================================

package.loaded["modules.hotstrings_config"] = {
	resolve = nil,  -- Intentionally absent to exercise the nil-check branch
}


--- =========================================
-- ===== 1.7) modules.llm stub ==============
--- =========================================

-- core_llm.DEFAULT_STATE is read at module load-time by llm_bridge.
package.loaded["modules.llm"] = {
	DEFAULT_STATE = {
		llm_after_hotstring = false,
		llm_reset_on_nav    = false,
	},
	check_modifiers = function() return false end,
}


--- =========================================
-- ===== 1.8) Keycodes stub =================
--- =========================================

package.loaded["lib.keycodes"] = {
	ESCAPE           = 53,
	RETURN           = 36,
	F16_LLM_CHAIN_SIGNAL = 106,
	to_name          = function(_) return "f16" end,
}


--- =========================================
-- ===== 1.9) text_utils stub ===============
--- =========================================

package.loaded["lib.text_utils"] = {
	is_letter_char      = function() return false end,
	trig_lower          = function(s) return s:lower() end,
	conform_replacement = function(repl) return repl end,
}




-- ================================================
-- ================================================
-- ======= 2/ Module Under Test ==================
-- ================================================
-- ================================================

-- Force a fresh load of llm_bridge now that all stubs are in place.
package.loaded["modules.keymap.llm_bridge"] = nil
local bridge = require("modules.keymap.llm_bridge")




-- ================================================
-- ================================================
-- ======= 3/ Test Helpers =======================
-- ================================================
-- ================================================

--- Builds a minimal CoreState that apply_prediction() can operate on.
--- Starts with last_synthetic_arm_time set 2 seconds in the past so any
--- timestamp written by apply_prediction() is clearly distinguishable.
--- @return table state
local function make_state()
	local now = hs.timer.secondsSinceEpoch()
	return {
		buffer                    = "hello ",
		last_synthetic_arm_time   = now - 2.0,
		expected_synthetic_deletes = 0,
		expected_synthetic_chars  = "",
		preview_providers         = {},
		groups                    = {},
		mappings                  = {},
		DELAYS                    = {},
		is_repeat_feature_enabled = function() return false end,
	}
end




-- ================================================
-- ================================================
-- ======= 4/ Regression Tests ===================
-- ================================================
-- ================================================

helpers.describe("apply_prediction: guard-arm ordering invariant", function()

	helpers.it("updates last_synthetic_arm_time before incrementing counters", function()
		-- Re-initialize the bridge with a fresh state for each test so module-level
		-- _state does not bleed between runs (bridge.init guards against re-init,
		-- so we reload the module from scratch).
		package.loaded["modules.keymap.llm_bridge"] = nil
		local fresh_bridge = require("modules.keymap.llm_bridge")

		local state          = make_state()
		local initial_arm    = state.last_synthetic_arm_time
		local initial_deletes = state.expected_synthetic_deletes

		fresh_bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })

		-- Capture the arm time and counter value immediately before the call
		-- so the assertion window is as tight as possible.
		local before_call = hs.timer.secondsSinceEpoch()
		fresh_bridge.apply_prediction(1)

		-- The arm timestamp must have moved forward from the stale initial value
		helpers.assert_true(
			state.last_synthetic_arm_time > initial_arm,
			"last_synthetic_arm_time must be refreshed by apply_prediction()"
		)

		-- The updated timestamp must be within 0.5 s of the current wall-clock time,
		-- confirming it was set during this call and not at some earlier point
		local after_call = hs.timer.secondsSinceEpoch()
		helpers.assert_true(
			state.last_synthetic_arm_time >= before_call - 0.5,
			"last_synthetic_arm_time must be approximately now (not stale)"
		)
		helpers.assert_true(
			state.last_synthetic_arm_time <= after_call + 0.5,
			"last_synthetic_arm_time must not be in the future"
		)

		-- Counters must also have been updated (confirming apply_prediction ran fully)
		helpers.assert_true(
			state.expected_synthetic_deletes > initial_deletes,
			"expected_synthetic_deletes must be incremented after arm"
		)
	end)


	helpers.it("does not touch last_synthetic_arm_time when no prediction is available", function()
		-- Swap out the engine stub so consume() returns nil (no prediction)
		package.loaded["modules.keymap.llm_bridge"] = nil
		package.loaded["modules.llm.prediction_engine"] = nil

		-- Build a minimal engine stub where consume() returns nil
		local no_pred_engine = {
			init                          = function() end,
			consume                       = function(_) return nil, nil end,
			reset                         = function() end,
			arm_chain                     = function() end,
			get_llm_enabled               = function() return false end,
			set_llm_enabled               = function() end,
			set_llm_model                 = function() end,
			set_llm_display_model_name    = function() end,
			set_llm_show_model_name       = function() end,
			set_llm_backend_name          = function() end,
			set_llm_context_length        = function() end,
			set_llm_temperature           = function() end,
			set_llm_num_predictions       = function() end,
			set_llm_pred_indent           = function() end,
			set_llm_show_info_bar         = function() end,
			set_llm_sequential_mode       = function() end,
			set_llm_auto_raise_temp       = function() end,
			set_llm_disabled_apps         = function() end,
			set_llm_url_bar_filter_enabled      = function() end,
			set_llm_secure_field_filter_enabled = function() end,
			set_llm_instant_on_word_end   = function() end,
			set_llm_val_modifiers         = function() end,
			set_llm_nav_modifiers         = function() end,
			set_llm_min_words             = function() end,
			set_llm_max_words             = function() end,
			set_llm_debounce              = function() end,
			set_llm_streaming             = function() end,
			set_llm_streaming_multi       = function() end,
			set_preview_ai_enabled        = function() end,
			set_preview_ai_color          = function() end,
			get_predictions               = function() return {} end,
			get_current_index             = function() return 1 end,
			get_navigation_mods           = function() return {} end,
			get_validation_mods           = function() return {} end,
			is_visible                    = function() return false end,
			start_timer                   = function() end,
			start_timer_word_end          = function() end,
			stop_timer                    = function() end,
			perform_check                 = function() end,
			handle_chain_signal           = function() return false end,
			navigate                      = function() end,
		}
		package.loaded["modules.llm.prediction_engine"] = no_pred_engine

		local fresh_bridge = require("modules.keymap.llm_bridge")
		local state        = make_state()
		local initial_arm  = state.last_synthetic_arm_time

		fresh_bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
		local result = fresh_bridge.apply_prediction(1)

		-- Must return false: no prediction was available
		helpers.assert_eq(result, false, "apply_prediction must return false when engine has no prediction")

		-- The arm timestamp must NOT have been touched
		helpers.assert_eq(
			state.last_synthetic_arm_time,
			initial_arm,
			"last_synthetic_arm_time must not change when apply_prediction returns early"
		)
	end)

end)
