--- tests/unit/modules/llm/test_on_fail_cancels_watchdog.lua

--- ==============================================================================
--- MODULE: streaming_handler on_fail watchdog cancellation regression test
--- DESCRIPTION:
--- Regression guard for the invariant that on_fail() always cancels the stream
--- watchdog timer when the failure belongs to the current fetch window. A stale
--- watchdog that fires after a failure would call tooltip.show_predictions with
--- empty or partial data, silently corrupting the UI state.
---
--- FEATURES & RATIONALE:
--- 1. Watchdog armed via M.arm_watchdog() — confirms the timer is created and
---    running before on_fail() is invoked.
--- 2. on_fail() with matching fetch_id — the cancellation path under test.
--- 3. Timer stopped check — the hs.timer stub records .running state; we assert
---    it is false after on_fail() returns.
--- 4. No show_predictions after fire — the stopped timer must not invoke the
---    tooltip even if the test harness explicitly fires all pending timers.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Stubs lib.timings so the module loads without the real TOML registry.
--- Returns a fixed STREAM_WATCHDOG_SEC so timer assertions are deterministic.
local WATCHDOG_DELAY_SEC = 5.0

package.loaded["infra.timings"] = {
	sec = function(_section, _key) return WATCHDOG_DELAY_SEC end,
	ms  = function(_section, _key) return WATCHDOG_DELAY_SEC * 1000 end,
}

--- Stubs modules.llm.parser — the handler requires it at load time.
package.loaded["modules.llm.parser"] = {
	strip_thinking     = function(s) return s end,
	process_prediction = function(_, _, raw) return { to_type = raw, deletes = 0, chunks = {}, nw = raw } end,
}

--- Load lib.logger first so the handler can require it.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Load the module under test with a clean hs stub.
local Handler = helpers.load_with_stubs("modules.llm.streaming_handler")
local hs_stub = _G.hs


--- Builds the minimal tooltip stub and records show_predictions calls.
local function make_tooltip_stub()
	local stub = {
		show_predictions_calls = 0,
		hidden = false,
	}
	stub.show_predictions = function(_preds, _idx, _ai, _info, _val, _indent, _nav, _tint, _loading, _slots)
		stub.show_predictions_calls = stub.show_predictions_calls + 1
	end
	stub.hide               = function() stub.hidden = true end
	stub.get_current_index  = function() return 1 end
	stub.make_diff_styled   = function(_chunks, _nw) return true end
	stub.tint               = function(_name) return {} end
	stub.mark_chain_complete = function() end
	return stub
end

--- Builds a minimal core_llm stub.
local function make_core_llm_stub()
	return {
		get_active_profile  = function() return nil end,
		get_current_model   = function() return "test-model" end,
		get_backend         = function() return "mlx" end,
		fetch_llm_prediction = function() end,
	}
end

--- Builds a minimal keylogger stub.
local function make_keylogger_stub()
	return {
		log_llm          = function() end,
		log_llm_suggested = function() end,
	}
end

--- Builds a minimal streaming context table for a given fetch_id.
--- @param fetch_id number The current fetch generation counter value.
--- @param get_fetch_id_fn function Returns the live counter (mimics a closure over state).
--- @return table ctx
local function make_ctx(fetch_id, get_fetch_id_fn)
	return {
		buffer                   = "test buffer",
		my_fetch_id              = fetch_id,
		get_fetch_id             = get_fetch_id_fn,
		is_streaming_multi_enabled = false,
		is_streaming_enabled     = false,
		num_predictions          = 3,
		show_info_bar            = false,
		streaming_info_bar       = nil,
		prediction_indent        = 0,
		validation_mods          = { "none" },
		navigation_mods          = {},
		model_to_use             = "test-model",
		llm_display_name         = "Test Model",
		profile_name             = nil,
		build_info_bar_text      = function() return nil end,
		resolve_backend_label    = function() return "mlx" end,
		is_noise_pred            = function(_) return false end,
		reset_llm_dismiss_timer  = function() end,
		pending_predictions_ref  = { value = {} },
		predictions_visible_ref  = { value = false },
		tail                     = "",
		is_ai_preview_enabled    = false,
	}
end





-- ==========================================
-- ==========================================
-- ======= 1/ Module init and surface =======
-- ==========================================
-- ==========================================

helpers.describe("streaming_handler: module surface", function()
	helpers.it("exposes init, arm_watchdog, stop_watchdog, build_callbacks, reset_failure_count", function()
		helpers.assert_eq(type(Handler.init),                "function")
		helpers.assert_eq(type(Handler.arm_watchdog),        "function")
		helpers.assert_eq(type(Handler.stop_watchdog),       "function")
		helpers.assert_eq(type(Handler.build_callbacks),     "function")
		helpers.assert_eq(type(Handler.reset_failure_count), "function")
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 2/ on_fail cancels watchdog =======
-- ===========================================
-- ===========================================

helpers.describe("streaming_handler: on_fail() cancels the stream watchdog", function()

	--- Shared setup: reinitialize the module for a clean state per describe block.
	--- load_with_stubs() already reset package.loaded for streaming_handler,
	--- but lib.timings must stay stubbed so the module reloads cleanly here.
	local tooltip    = make_tooltip_stub()
	local core_llm   = make_core_llm_stub()
	local keylogger  = make_keylogger_stub()

	Handler.init({ core_llm = core_llm, tooltip = tooltip, keylogger = keylogger })

	helpers.it("arm_watchdog creates a running timer", function()
		-- Reset hs stub timers to a clean slate for this test
		hs_stub.__reset()

		local fetch_id = 42
		local ctx = make_ctx(fetch_id, function() return fetch_id end)
		Handler.arm_watchdog(ctx)

		-- The hs stub records every doAfter call in __timers
		local timers = hs_stub.timer.__timers
		helpers.assert_true(#timers >= 1, "expected at least one timer to be armed")
		local watchdog = timers[#timers]
		helpers.assert_true(watchdog.running, "watchdog timer must be running after arm_watchdog")
	end)


	helpers.it("on_fail() with matching fetch_id stops the watchdog timer", function()
		hs_stub.__reset()

		local fetch_id = 42
		local ctx = make_ctx(fetch_id, function() return fetch_id end)

		Handler.arm_watchdog(ctx)
		local timers = hs_stub.timer.__timers
		local watchdog = timers[#timers]
		helpers.assert_true(watchdog.running, "precondition: watchdog must be running before on_fail")

		local _on_partial, _on_success, on_fail = Handler.build_callbacks(ctx)
		on_fail()

		helpers.assert_eq(watchdog.running, false, "watchdog must be stopped after on_fail()")
	end)


	helpers.it("on_fail() with matching fetch_id does not call show_predictions via the watchdog", function()
		hs_stub.__reset()

		local fetch_id = 42
		local ctx = make_ctx(fetch_id, function() return fetch_id end)
		-- Mark visible so the watchdog body would normally call show_predictions if it ran
		ctx.predictions_visible_ref.value = true
		ctx.pending_predictions_ref.value = { { to_type = "word", chunks = {}, nw = "word" } }

		Handler.arm_watchdog(ctx)
		local _on_partial, _on_success, on_fail = Handler.build_callbacks(ctx)
		on_fail()

		-- Record how many show_predictions calls on_fail() itself legitimately made,
		-- then reset the counter and fire all timers. The stopped watchdog must not
		-- add any further calls.
		tooltip.show_predictions_calls = 0
		hs_stub.timer.__fire_all()

		helpers.assert_eq(tooltip.show_predictions_calls, 0,
			"stopped watchdog must not call show_predictions when fired after on_fail()")
	end)


	helpers.it("on_fail() with stale fetch_id leaves the watchdog running", function()
		hs_stub.__reset()

		local live_fetch_id = 99
		-- The closure returns the updated live counter (simulates a newer request)
		local ctx = make_ctx(42, function() return live_fetch_id end)

		Handler.arm_watchdog(ctx)
		local timers = hs_stub.timer.__timers
		local watchdog = timers[#timers]
		helpers.assert_true(watchdog.running, "precondition: watchdog must be running")

		local _on_partial, _on_success, on_fail = Handler.build_callbacks(ctx)
		-- my_fetch_id (42) != live fetch_id (99) → on_fail is a stale callback and must bail out
		on_fail()

		helpers.assert_true(watchdog.running, "watchdog must remain running when on_fail is stale")
	end)


	helpers.it("stop_watchdog() is idempotent and cancels nothing the second time", function()
		hs_stub.__reset()
		-- "Does not crash" was the whole assertion. What the second call must not
		-- do is cancel a timer it does not own: this module is reused across
		-- requests, and a stop that reached into the next request's watchdog would
		-- leave a stream running with nothing left to time it out.
		Handler.stop_watchdog()
		local after_first = #hs_stub.timer.__timers
		Handler.stop_watchdog()
		helpers.assert_eq(#hs_stub.timer.__timers, after_first,
			"a second stop must touch no timer — there is none left that belongs to it")
	end)


	helpers.it("arm_watchdog replaces a previously armed watchdog without crashing", function()
		hs_stub.__reset()

		local fetch_id = 7
		local ctx = make_ctx(fetch_id, function() return fetch_id end)

		-- Arm twice in succession — second call must stop the first timer
		Handler.arm_watchdog(ctx)
		local timers_after_first = #hs_stub.timer.__timers
		Handler.arm_watchdog(ctx)

		helpers.assert_true(#hs_stub.timer.__timers > timers_after_first,
			"second arm_watchdog must create a new timer")

		-- The first timer must have been stopped when the second was armed
		local first_timer = hs_stub.timer.__timers[timers_after_first]
		helpers.assert_eq(first_timer.running, false,
			"previously armed watchdog must be stopped when arm_watchdog is called again")
	end)

end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ Watchdog body guard (fetch_id mismatch) =======
-- ==========================================================
-- ==========================================================

helpers.describe("streaming_handler: watchdog body respects fetch_id guard", function()

	local tooltip2  = make_tooltip_stub()
	local core_llm2 = make_core_llm_stub()
	local keylogger2 = make_keylogger_stub()

	--- Reload the module so _core_llm is nil again (fresh state, avoids duplicate-init warning).
	package.loaded["modules.llm.streaming_handler"] = nil
	local Handler2 = require("modules.llm.streaming_handler")
	Handler2.init({ core_llm = core_llm2, tooltip = tooltip2, keylogger = keylogger2 })

	helpers.it("watchdog body does not call show_predictions when fetch_id has advanced", function()
		hs_stub.__reset()
		tooltip2.show_predictions_calls = 0

		local live_id = { value = 1 }
		-- ctx.my_fetch_id = 1, but the live counter will be 2 when the watchdog fires
		local ctx = make_ctx(1, function() return live_id.value end)
		ctx.predictions_visible_ref.value = true
		ctx.pending_predictions_ref.value = { { to_type = "stale", chunks = {}, nw = "stale" } }

		Handler2.arm_watchdog(ctx)
		-- Simulate a new request arriving — bump the live counter
		live_id.value = 2

		-- Fire the watchdog; the body must bail out because fetch_id mismatch
		hs_stub.timer.__fire_all()

		helpers.assert_eq(tooltip2.show_predictions_calls, 0,
			"watchdog must not fire show_predictions when fetch_id has advanced")
	end)

end)
