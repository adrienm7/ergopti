--- tests/unit/modules/llm/test_llm_numeric_settings_coerced.lua

--- ==============================================================================
--- MODULE: Regression — every numeric LLM setting is coerced before it reaches
--- the shared prompt_builder
--- DESCRIPTION:
--- set_llm_min_words() has always coerced its argument with `tonumber(w) or
--- default`, and its comment states exactly why: a value read back from
--- config.toml or a half-written plist can be a STRING, and the shared
--- prompt_builder then compares it against a number. Four sibling setters
--- reaching the very same comparisons assigned their argument raw:
---
---   set_llm_num_predictions  -> `num_predictions > 1`          (prompt_builder:119)
---   set_llm_context_length   -> `context_window_chars > 0`     (prompt_builder:148)
---   set_llm_temperature      -> `t <= GREEDY_TEMP_THRESHOLD`   (prompt_builder:127)
---   set_llm_debounce         -> `inactivity_debounce_sec < 0`  (start_inactivity_timer)
---
--- Neither infra/preferences.lua nor ui/menu/menu_state.lua coerces, and the
--- shared TOML codec falls back to a bare string for anything its two numeric
--- patterns miss — so an untrusted string genuinely reaches these setters.
---
--- WHY IT WAS FATAL: PromptBuilder.build runs inside perform_check, which is the
--- body of the module-level hs.timer debounce. Hammerspoon pcalls timer
--- callbacks, so the throw went to the Console and never reached infra/logger —
--- not even "Request signature accepted." was emitted. The health dot stayed
--- green, the backend stayed ready, and no prediction ever appeared again for
--- the session.
---
--- APPROACH — the test MUST drive the REAL call path. Grepping for `tonumber`
--- would be a false green (it would pass against any incidental match), so this
--- file loads the REAL shared prompt_builder through the REAL Hammerspoon shim,
--- feeds string settings through the REAL public setters, and asserts that
--- perform_check reaches the backend dispatcher. With an uncoerced value the
--- shared module throws, the new pcall guard aborts the request, and the
--- dispatcher is never reached.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.prediction_engine"] = nil
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")





-- ===================================
-- ===================================
-- ======= 1/ Dependency Stubs =======
-- ===================================
-- ===================================

-- Stub modules.llm (core_llm). get_current_model is required at module-load time
-- by prediction_engine, so it must be present (see tests/meta/
-- test_modules_llm_stub_completeness.lua). fetch_llm_prediction is the backend
-- dispatcher whose reachability is the load-bearing assertion of this file.
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
		llm_show_info_bar       = false,
		llm_sequential_mode     = false,
		llm_debounce            = 0.3,
		llm_auto_raise_temp     = true,
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
	cancel_streaming        = function() return true end,
	is_backend_ready        = function() return true end,
	get_active_profile      = function() return { label = "Test profile" } end,
	fetch_llm_prediction    = function(...) end,
}

package.loaded["modules.llm.warmup_controller"] = {
	schedule_warmup_with_retry = function(_reason) end,
	init                       = function(_cfg) return true end,
	start                      = function() end,
	stop                       = function() end,
}

-- set_llm_enabled lazily requires api_mlx to stop/resume its self-retry chain
-- (see test_mlx_warmup_gated_on_disable.lua); stub it so no real server code runs.
package.loaded["modules.llm.api_mlx"] = {
	stop_warmup   = function() end,
	resume_warmup = function() end,
}

package.loaded["modules.llm.streaming_handler"] = {
	init                = function(_cfg) return true end,
	build_callbacks     = function(_cfg) return function() end, function() end, function() end end,
	arm_watchdog        = function(_cfg) return true end,
	stop_watchdog       = function() return true end,
	reset_failure_count = function() end,
	cancel_streaming    = function() return true end,
}

package.loaded["modules.llm.app_filter"] = {
	is_blocked = function(_state, _apps, _url, _secure) return false end,
}

package.loaded["modules.llm.api_common"] = {
	MIN_CALL_INTERVAL_SEC         = 0.5,
	get_retry_policy              = function() return 2, 0.18, 5 end,
	get_rate_limit_min_interval_s = function(_backend) return 0 end,
}

package.loaded["infra.i18n"] = {
	t   = function(key) return key end,
	get = function(key) return key end,
}

package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }

package.loaded["ui.tooltip"] = {
	set_navigate_callback = function(_) end,
	set_enter_validates   = function(_) end,
	set_chain_start       = function(_) return true end,
	mark_chain_complete   = function() return true end,
	get_current_index     = function() return nil end,
	navigate              = function(_) end,
	show                  = function() end,
	hide                  = function() return true end,
	set_llm_timeout       = function(_) end,
	reset_llm_timer       = function() return true end,
	show_loading          = function(...) return true end,
	show_predictions      = function(...) return true end,
	tint                  = function(_) return nil end,
}

package.loaded["modules.keylogger"] = {
	get_live_stats    = function() return { wpm_physical = 0 } end,
	log_llm_dismissed = function(_, _preds) end,
}

-- perform_check consults script_control through package.loaded to avoid a
-- circular require. Another test file may have left a paused instance cached,
-- which would make perform_check return before the prompt builder ever runs and
-- turn every assertion below into a false green. Pin it to "not paused" and
-- restore the previous value once this file is done.
local _prev_script_control = package.loaded["modules.shortcuts.script_control"]
package.loaded["modules.shortcuts.script_control"] = {
	is_paused = function() return false end,
}

-- THE point of this file: the REAL Hammerspoon shim over the REAL shared
-- prompt_builder, not the arithmetic-free stub used by test_prediction_engine.
package.loaded["modules.llm.prompt_builder"] = nil
package.loaded["llm.prompt_builder"]         = nil
local SharedPromptBuilder = require("llm.prompt_builder")
local HsPromptBuilder     = require("modules.llm.prompt_builder")

local PE = require("modules.llm.prediction_engine")
PE.init({ buffer = "bonjour le mon", mappings = {}, DELAYS = { llm_prediction = 0 } })





-- ==============================================
-- ==============================================
-- ======= 2/ The Real Path Is Under Test =======
-- ==============================================
-- ==============================================

-- Guard against the whole file silently degrading into a tautology if a future
-- change re-stubs the prompt builder: if these constants/functions are absent we
-- are no longer exercising the code that actually throws on a string.
helpers.describe("numeric coercion regression exercises the real prompt_builder", function()
	helpers.it("the shared prompt_builder is loaded, not a stub", function()
		helpers.assert_true(type(SharedPromptBuilder.build_params) == "function",
			"the REAL shared llm.prompt_builder must be loaded — a stub would make every assertion below meaningless")
		helpers.assert_eq(SharedPromptBuilder.GREEDY_TEMP_THRESHOLD, 0.15,
			"shared prompt_builder constants must be the real ones")
	end)

	helpers.it("the Hammerspoon shim delegates to the shared module", function()
		helpers.assert_true(type(HsPromptBuilder.build) == "function",
			"the REAL modules.llm.prompt_builder shim must be loaded")
		-- A raw string num_predictions must genuinely throw in the shared module —
		-- this is the failure the setters exist to prevent
		local ok = pcall(SharedPromptBuilder.build_params, "bonjour le mon", {
			max_words = 0, min_words = 2, num_predictions = "3",
			temperature = 0.1, auto_raise_temp = true,
		})
		helpers.assert_true(ok == false,
			"a string num_predictions must still throw inside the shared builder — otherwise this regression no longer has teeth")
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 3/ Setters Coerce On The Real Path =======
-- ==================================================
-- ==================================================

--- Runs a forced perform_check with the backend dispatcher stubbed out and
--- reports whether the dispatcher was reached and whether anything escaped.
--- @return boolean dispatched True when core_llm.fetch_llm_prediction was called.
--- @return boolean ok False when perform_check let an error propagate.
--- @return any err The propagated error, when any.
local function run_perform_check()
	local core       = package.loaded["modules.llm"]
	local dispatched = false
	local prev_fetch = core.fetch_llm_prediction
	core.fetch_llm_prediction = function(...) dispatched = true end

	-- force_trigger = true skips the freshness and word-count gates so the call
	-- goes straight through the prompt builder to the dispatcher
	local ok, err = pcall(function() PE.perform_check(true) end)

	core.fetch_llm_prediction = prev_fetch
	return dispatched, ok, err
end

helpers.describe("prediction_engine — numeric settings survive a string from config", function()

	helpers.it('set_llm_num_predictions("3") still reaches the backend dispatcher', function()
		PE.set_llm_enabled(true)
		PE.set_llm_auto_raise_temp(true)   -- The shipped default; puts line 119 on the DEFAULT path
		PE.set_llm_temperature(0.1)
		PE.set_llm_context_length(0)
		PE.set_llm_num_predictions("3")

		local dispatched, ok, err = run_perform_check()
		PE.set_llm_enabled(false)

		helpers.assert_true(ok, "perform_check must not propagate: " .. tostring(err))
		helpers.assert_true(dispatched,
			"a string llm_num_predictions must be coerced by the setter — otherwise the shared prompt_builder throws " ..
			"inside the debounce timer and no prediction ever appears again for the session")
	end)

	helpers.it('set_llm_context_length("500") still reaches the backend dispatcher', function()
		PE.set_llm_enabled(true)
		PE.set_llm_auto_raise_temp(false)
		PE.set_llm_temperature(0.1)
		PE.set_llm_num_predictions(1)
		PE.set_llm_context_length("500")

		local dispatched, ok, err = run_perform_check()
		PE.set_llm_enabled(false)

		helpers.assert_true(ok, "perform_check must not propagate: " .. tostring(err))
		helpers.assert_true(dispatched,
			"a string llm_context_length must be coerced by the setter — cap_context compares it against 0")
	end)

	helpers.it('set_llm_temperature(".5") still reaches the backend dispatcher', function()
		PE.set_llm_enabled(true)
		-- Single prediction with no auto-raise routes temperature into the greedy
		-- comparison `t <= GREEDY_TEMP_THRESHOLD`, which throws on a string
		PE.set_llm_auto_raise_temp(false)
		PE.set_llm_num_predictions(1)
		PE.set_llm_context_length(0)
		PE.set_llm_temperature(".5")

		local dispatched, ok, err = run_perform_check()
		PE.set_llm_enabled(false)

		helpers.assert_true(ok, "perform_check must not propagate: " .. tostring(err))
		helpers.assert_true(dispatched,
			"a string llm_temperature must be coerced by the setter — compute_temperature compares it against the greedy threshold")
	end)

	helpers.it('set_llm_debounce("0.25") keeps the inactivity timer armable', function()
		PE.set_llm_debounce("0.25")
		PE.set_llm_enabled(true)

		-- start_inactivity_timer opens with `inactivity_debounce_sec < 0`, which
		-- throws on a string. This runs on the per-keystroke path.
		local ok, err = pcall(function() PE.start_timer() end)
		PE.stop_timer()
		PE.set_llm_enabled(false)

		helpers.assert_nil(err, "start_inactivity_timer compares the debounce against 0: " .. tostring(err))
		helpers.assert_true(ok, "a string llm_debounce must be coerced by the setter")
	end)

	helpers.it("set_llm_num_predictions floors and clamps to at least one prediction", function()
		PE.set_llm_enabled(true)
		PE.set_llm_auto_raise_temp(true)
		PE.set_llm_temperature(0.1)
		PE.set_llm_context_length(0)

		-- A zero (or a fraction flooring to zero) would ask the backend for nothing
		PE.set_llm_num_predictions("0")
		local dispatched_zero, ok_zero = run_perform_check()
		helpers.assert_true(ok_zero and dispatched_zero,
			"a zero prediction count must be clamped up, not forwarded to the backend")

		PE.set_llm_num_predictions(2.7)
		local dispatched_frac, ok_frac = run_perform_check()
		PE.set_llm_enabled(false)
		helpers.assert_true(ok_frac and dispatched_frac,
			"a fractional prediction count must be floored to an integer")
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 4/ The Swallow Boundary Is Guarded =======
-- ==================================================
-- ==================================================

-- Defence in depth for the same failure class. Even with every setter coerced, a
-- future throw inside PromptBuilder.build would be swallowed by Hammerspoon's
-- timer pcall and produce the identical invisible, permanent "green dot but no
-- prediction" state. perform_check must catch it and log an ERROR instead.

helpers.describe("prediction_engine — a throwing PromptBuilder is contained and logged", function()
	helpers.it("perform_check aborts cleanly instead of escaping into the timer callback", function()
		-- prediction_engine captures PromptBuilder at require-time, so the throwing
		-- stub must be installed before a FRESH instance is loaded
		local prev_builder = package.loaded["modules.llm.prompt_builder"]
		local build_calls  = 0
		package.loaded["modules.llm.prompt_builder"] = {
			build = function()
				build_calls = build_calls + 1
				error("simulated prompt builder failure")
			end,
		}
		package.loaded["modules.llm.prediction_engine"] = nil
		local PE_throwing = require("modules.llm.prediction_engine")
		PE_throwing.init({ buffer = "bonjour le mon", mappings = {}, DELAYS = { llm_prediction = 0 } })

		local core       = package.loaded["modules.llm"]
		local dispatched = false
		local prev_fetch = core.fetch_llm_prediction
		core.fetch_llm_prediction = function(...) dispatched = true end

		PE_throwing.set_llm_enabled(true)
		local ok, err = pcall(function() PE_throwing.perform_check(true) end)
		PE_throwing.set_llm_enabled(false)

		core.fetch_llm_prediction                     = prev_fetch
		package.loaded["modules.llm.prompt_builder"]  = prev_builder
		package.loaded["modules.llm.prediction_engine"] = nil

		-- Without this the whole case is a tautology: if perform_check bailed out
		-- before the builder (paused, disabled, no state…) both assertions below
		-- would pass against completely unguarded code.
		helpers.assert_eq(build_calls, 1,
			"perform_check must actually reach PromptBuilder.build — otherwise this case proves nothing")
		helpers.assert_true(ok,
			"perform_check must pcall PromptBuilder.build — an unguarded throw is invisible (hs.timer routes it to the " ..
			"Console, never to infra/logger) and permanently kills predictions for the session: " .. tostring(err))
		helpers.assert_true(dispatched == false,
			"a failed build must abort the request, not fall through to the dispatcher")
	end)
end)

-- Restore the pre-existing script_control entry so this file leaves no stub behind.
package.loaded["modules.shortcuts.script_control"] = _prev_script_control
