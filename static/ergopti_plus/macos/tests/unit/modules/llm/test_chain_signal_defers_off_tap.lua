--- tests/unit/modules/llm/test_chain_signal_defers_off_tap.lua

--- ==============================================================================
--- MODULE: Regression — the F16 chain signal must not run the LLM check inline
--- DESCRIPTION:
--- Accepting a prediction that chains into another one could freeze the keyboard.
---
--- ROOT CAUSE ENCODED:
--- handle_chain_signal is reached from the keymap CGEventTap callback
--- (llm_bridge.handle_llm_keys, called on the tap's thread before any other
--- routing). It used to call M.perform_check(true) inline. perform_check runs
--- AppFilter.is_blocked, which issues cross-process Accessibility queries against
--- whatever app currently has focus — an unbounded wait when that app is busy or
--- not responding. macOS disables an event tap whose callback overruns its
--- deadline (kCGEventTapDisabledByTimeout), and a disabled keymap tap means a
--- dead keyboard until it is re-armed.
---
--- WHY IT WAS SILENT:
--- Nothing throws. On a responsive frontmost app the AX query returns in
--- microseconds and the inline call is indistinguishable from the deferred one.
--- The failure only appears against a hung app — precisely when the user can
--- least afford to lose the keyboard — so it never reproduced in normal use.
---
--- The fix defers by one run-loop tick, making this path structurally identical
--- to the CHAIN_FALLBACK_SEC timer that calls the very same function.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.prediction_engine"] = nil
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

-- Minimal core_llm surface: prediction_engine reads DEFAULT_STATE at load time
-- and queries the backend during perform_check, which this test never reaches.
package.loaded["modules.llm"] = {
	DEFAULT_STATE = {
		llm_enabled = false, llm_temperature = 0.1, llm_context_length = 4000,
		llm_min_words = 2, llm_max_words = 0, llm_num_predictions = 3,
		llm_pred_indent = 0, llm_val_modifiers = { "alt" }, llm_nav_modifiers = { "ctrl" },
		llm_show_info_bar = true, llm_sequential_mode = false, llm_debounce = 0.3,
		llm_auto_raise_temp = false, llm_streaming = false, llm_streaming_multi = false,
		llm_instant_on_word_end = false,
	},
	get_current_model = function() return "llama3" end,
	get_backend       = function() return "ollama" end,
	cancel_streaming  = function() return true end,
	fetch_llm_prediction = function() end,
}
-- The real export is is_blocked(state, apps, url_filter, secure_filter): the very
-- call whose cross-process Accessibility queries make an inline perform_check
-- unsafe on the tap thread.
package.loaded["modules.llm.app_filter"] = {
	is_blocked = function(_state, _apps, _url, _secure) return false end,
}
package.loaded["modules.llm.streaming_handler"] = {
	init                = function(_cfg) return true end,
	build_callbacks     = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog        = function(_cfg) return true end,
	stop_watchdog       = function() return true end,
	reset_failure_count = function() end,
	cancel_streaming    = function() return true end,
}
package.loaded["modules.llm.api_common"] = {
	MIN_CALL_INTERVAL_SEC         = 0.5,
	get_retry_policy              = function() return 2, 0.18, 5 end,
	get_rate_limit_min_interval_s = function(_backend) return 0 end,
}
package.loaded["infra.i18n"]     = { t = function(k) return k end, get = function(k) return k end }
package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
-- set_navigate_callback and set_enter_validates are called at module load time.
package.loaded["ui.tooltip"] = {
	set_navigate_callback = function(_) end,
	set_enter_validates   = function(_) end,
	set_chain_start       = function(_) return true end,
	mark_chain_complete   = function() end,
	get_current_index     = function() return nil end,
	navigate              = function(_) end,
	show                  = function() end,
	hide                  = function() return true end,
	set_llm_timeout       = function(_) end,
	reset_llm_timer       = function() end,
	show_loading          = function(...) return true end,
	show_predictions      = function(...) end,
	tint                  = function(_) return nil end,
}
package.loaded["modules.keylogger"] = {
	get_live_stats    = function() return { wpm_physical = 0 } end,
	log_llm_dismissed = function(_, _preds) end,
}

local PE = require("modules.llm.prediction_engine")





-- ==================================================
-- ==================================================
-- ======= 1/ The Chain Signal Leaves The Tap =======
-- ==================================================
-- ==================================================

helpers.describe("F16 chain signal defers the LLM check off the event tap", function()
	--- Arms a chain and reports what handle_chain_signal did, with perform_check
	--- swapped for a counter. handle_chain_signal calls it through the module
	--- table, so the substitution is observed by the code under test.
	--- @return table Counts before and after the run loop turns.
	local function run_chain_signal()
		local calls = 0
		local real_perform = PE.perform_check
		PE.perform_check = function() calls = calls + 1 end

		PE.init({
			buffer   = "hello wor",
			mappings = {},
			DELAYS   = { llm_prediction = 0 },
			suppress_rescan_keep_buffer = function() end,
		})
		PE.arm_chain()

		local consumed   = PE.handle_chain_signal(PE.KEYCODE_LLM_CHAIN)
		local during_tap = calls
		hs.timer.__fire_all()
		local after_tick = calls

		PE.perform_check = real_perform
		return { consumed = consumed, during_tap = during_tap, after_tick = after_tick }
	end

	helpers.it("does not run perform_check inside the tap callback", function()
		local r = run_chain_signal()
		helpers.assert_eq(r.during_tap, 0,
			"perform_check ran synchronously inside handle_chain_signal, which is the body of "
			.. "the keymap CGEventTap: its Accessibility queries can stall the tap past the "
			.. "macOS deadline and get it disabled (kCGEventTapDisabledByTimeout), killing the keyboard")
	end)

	helpers.it("still runs perform_check on the next run-loop turn", function()
		local r = run_chain_signal()
		helpers.assert_eq(r.after_tick, 1,
			"the chained prediction must still fire exactly once after the deferral — "
			.. "deferring must not drop the check (G2), and the CHAIN_FALLBACK_SEC timer "
			.. "must have been stopped so it cannot fire a second one")
	end)

	helpers.it("still consumes the F16 event", function()
		local r = run_chain_signal()
		helpers.assert_true(r.consumed,
			"handle_chain_signal must keep returning true so the synthetic F16 is swallowed "
			.. "and never reaches the buffer as a real keystroke")
	end)

	for _, case in ipairs({
		{ name = "throw", build = function() error("CHAIN_DEFER_THROW") end },
		{ name = "nil", build = function() return nil end },
		{
			name = "stopped handle",
			build = function(original, delay, callback)
				local timer = original(delay, callback)
				timer.running = false
				return timer
			end,
		},
	}) do
		helpers.it("retains the fallback when F16 deferral returns " .. case.name, function()
			PE.reset()
			PE.init({
				buffer = "hello wor",
				mappings = {},
				DELAYS = { llm_prediction = 0 },
				suppress_rescan_keep_buffer = function() end,
			})
			helpers.assert_eq(PE.arm_chain(), true)
			local fallback = hs.timer.__timers[#hs.timer.__timers]
			local calls = 0
			local real_perform = PE.perform_check
			PE.perform_check = function() calls = calls + 1 end
			local original = hs.timer.doAfter
			hs.timer.doAfter = function(delay, callback)
				return case.build(original, delay, callback)
			end

			local ok, consumed = pcall(PE.handle_chain_signal, PE.KEYCODE_LLM_CHAIN)
			hs.timer.doAfter = original
			helpers.assert_true(ok, "F16 constructor failure must not escape the eventtap")
			helpers.assert_eq(consumed, true,
				"the internal F16 signal must never leak to the application")
			helpers.assert_eq(PE.is_chain_pending(), true,
				"the already-owned fallback remains authoritative")
			fallback:fire()
			helpers.assert_eq(calls, 1,
				"exactly one chained check must survive through the retained fallback")
			PE.perform_check = real_perform
		end)
	end
end)
