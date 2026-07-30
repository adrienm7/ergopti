--- tests/unit/modules/llm/test_prediction_engine_reset.lua

--- ==============================================================================
--- MODULE: prediction_engine.reset() Chain-Cleanup Tests
--- DESCRIPTION:
--- Regression tests for the D3 audit finding: M.reset() did not clear
--- chain_pending or stop _chain_trigger_timer, so a fallback timer that fired
--- after a reset could call M.perform_check() on stale state.
---
--- After the fix, M.reset() unconditionally sets chain_pending = false and
--- stops/nils _chain_trigger_timer before any other teardown.
---
--- FALSE-GREEN FIX (F-HIGH-14): the previous version of this test fabricated a
--- standalone table with its own arm_chain/reset methods, explicitly
--- documented as "a lightweight simulation" — it never required
--- modules.llm.prediction_engine, so a regression in the real M.reset()'s
--- ordering would not have been caught. This version loads the real module
--- (mirroring the dependency-stub set already used by test_prediction_engine.lua),
--- drives the real Engine.arm_chain()/Engine.reset(), fires the stub's pending
--- timers, and asserts no stale fetch fires post-reset.
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
local hs_stub = helpers.load_with_stubs("lib.logger") and _G.hs

-- Stub modules.llm (core_llm) — only the surface prediction_engine uses at
-- module-load time and in setters is needed. fetch_llm_prediction is
-- reassigned per-test to record whether the fallback chain timer dispatched.
package.loaded["modules.llm"] = {
	DEFAULT_STATE = {
		llm_enabled             = false,
		llm_temperature         = 0.1,
		llm_context_length      = 4000,
		llm_min_words           = 2,
		llm_max_words           = 0,
		llm_num_predictions     = 3,
		llm_pred_indent         = 0,
		llm_val_modifiers       = { "alt" },
		llm_nav_modifiers       = { "ctrl" },
		llm_show_info_bar       = true,
		llm_sequential_mode     = false,
		llm_debounce            = 0.3,
		llm_auto_raise_temp     = false,
		llm_streaming           = false,
		llm_streaming_multi     = false,
		llm_instant_on_word_end = false,
	},
	get_current_model       = function() return "llama3" end,
	get_backend             = function() return "ollama" end,
	set_llm_model_mlx       = function(_) end,
	set_llm_model_ollama    = function(_) end,
	set_runtime_llm_enabled = function(_) end,
	set_llm_streaming       = function(_) end,
	cancel_streaming        = function() end,
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

-- Stub PromptBuilder — build() (the real export shape) is called inside
-- perform_check. It returns (params, skip_reason, signature); a non-nil params
-- table drives the dispatch path.
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

-- Stub StreamingHandler — mirrors the real production surface (no ngram_predict).
package.loaded["modules.llm.streaming_handler"] = {
	init                = function(_cfg) end,
	build_callbacks     = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog        = function(_cfg) end,
	stop_watchdog       = function() end,
	reset_failure_count = function() end,
	cancel_streaming    = function() end,
}

-- Stub AppFilter.
package.loaded["modules.llm.app_filter"] = {
	is_blocked = function(_state, _apps, _url, _secure) return false end,
}

-- Stub api_common (required inline at module level).
package.loaded["modules.llm.api_common"] = {
	MIN_CALL_INTERVAL_SEC         = 0.5,
	get_retry_policy              = function() return 2, 0.18, 5 end,
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

-- Stub ui.tooltip — set_navigate_callback/set_enter_validates are called at
-- module load time; mark_chain_complete is called unconditionally by reset().
package.loaded["ui.tooltip"] = {
	set_navigate_callback = function(_) end,
	set_enter_validates   = function(_) end,
	set_chain_start       = function(_) end,
	mark_chain_complete   = function() end,
	get_current_index     = function() return nil end,
	navigate              = function(_) end,
	show                  = function() end,
	hide                  = function() end,
	hide_forced           = function() end,
	set_llm_timeout       = function(_) end,
	reset_llm_timer       = function() end,
	show_loading          = function(...) end,
	show_predictions      = function(...) end,
	tint                  = function(_) return nil end,
}

-- Stub modules.keylogger.
package.loaded["modules.keylogger"] = {
	get_live_stats    = function() return { wpm_physical = 0 } end,
	log_llm_dismissed = function(_, _preds) end,
}

-- Now load the prediction engine with all stubs registered.
local PE = require("modules.llm.prediction_engine")

-- core_state injected via M.init(): must supply suppress_rescan_keep_buffer,
-- which arm_chain() calls unconditionally.
local suppress_calls = {}
local core_state = {
	mappings = {},
	DELAYS   = { llm_prediction = 0 },
	suppress_rescan_keep_buffer = function(sec) suppress_calls[#suppress_calls + 1] = sec end,
}





-- =======================================================
-- =======================================================
-- ======= 2/ reset() chain-state cleanup contract =======
-- =======================================================
-- =======================================================

helpers.describe("prediction_engine.reset(): chain state cleanup (D3, real module)", function()

	helpers.it("is_chain_pending() returns false immediately after reset()", function()
		PE.init(core_state)
		PE.arm_chain()
		helpers.assert_eq(PE.is_chain_pending(), true, "arm_chain() must set chain_pending true")

		PE.reset()
		helpers.assert_eq(PE.is_chain_pending(), false, "reset() must clear chain_pending")
	end)

	helpers.it("reset() stops the fallback chain timer so it never fires the dispatch", function()
		local core = package.loaded["modules.llm"]
		local dispatched = false
		local prev_fetch = core.fetch_llm_prediction
		core.fetch_llm_prediction = function(...) dispatched = true end

		PE.init(core_state)
		PE.arm_chain()

		-- The most recently created timer is the fallback chain timer armed by arm_chain().
		local timers  = hs_stub.timer.__timers
		local chain_timer = timers[#timers]
		helpers.assert_true(chain_timer.running, "precondition: fallback chain timer must be running after arm_chain()")

		PE.reset()
		helpers.assert_eq(chain_timer.running, false, "reset() must stop the fallback chain timer")

		-- Simulate the race: the timer fires anyway (e.g. it was already queued
		-- on the runloop before :stop() took effect). Firing it must be a no-op
		-- because reset() cleared chain_pending before stopping the timer.
		chain_timer.running = true
		chain_timer:fire()

		core.fetch_llm_prediction = prev_fetch

		helpers.assert_true(not dispatched,
			"a stale fallback-chain timer firing after reset() must NOT dispatch a fetch")
	end)

	helpers.it("fallback timer body checks chain_pending and skips perform_check when reset() ran first", function()
		local core = package.loaded["modules.llm"]
		local dispatched = false
		local prev_fetch = core.fetch_llm_prediction
		core.fetch_llm_prediction = function(...) dispatched = true end

		PE.init(core_state)
		PE.arm_chain()
		PE.reset()

		-- Fire every timer the stub knows about (mirrors run.lua's hs_stub.timer.__fire_all()).
		-- Even if the runloop schedules the callback after reset(), the closure's own
		-- `if chain_pending then …` guard (cleared by reset()) must prevent perform_check.
		for _, t in ipairs(hs_stub.timer.__timers) do
			t.running = true
			t:fire()
		end

		core.fetch_llm_prediction = prev_fetch

		helpers.assert_true(not dispatched,
			"no stale fetch may fire after reset(), even when every pending timer is force-fired")
	end)

	helpers.it("reset() is safe to call when chain was never armed", function()
		PE.init(core_state)
		local ok = pcall(function() PE.reset() end)
		helpers.assert_true(ok, "reset() must not throw when no chain was ever armed")
		helpers.assert_eq(PE.is_chain_pending(), false)
	end)

	helpers.it("arm_chain() calls suppress_rescan_keep_buffer on the injected core_state", function()
		suppress_calls = {}
		PE.init(core_state)
		PE.arm_chain()
		helpers.assert_true(#suppress_calls >= 1,
			"arm_chain() must call core_state.suppress_rescan_keep_buffer")
		PE.reset()
	end)
end)
