--- tests/unit/modules/llm/core/test_init_default_state_shape.lua

--- ==============================================================================
--- MODULE: llm core (init.lua) Unit Tests
--- DESCRIPTION:
--- Validates the LLM core orchestrator: DEFAULT_STATE shape, profile getter/
--- setter contract, backend selection, and the modifier check helper used by
--- the keystroke routing layer.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.core.init_fixture"] = nil
local Fixture = require("tests.support.modules.llm.core.init_fixture")
local Core = Fixture.Core
local admit_ollama_start = Fixture.admit_ollama_start
local load_core_with_timer_spy = Fixture.load_core_with_timer_spy





-- ======================================
-- ======================================
-- ======= 1/ DEFAULT_STATE shape =======
-- ======================================
-- ======================================

helpers.describe("Core.DEFAULT_STATE", function()
	helpers.it("does not schedule a network bootstrap timer at require-time", function()
		local _, timer_spy_calls, hs_stub, _, load_time_calls = load_core_with_timer_spy()
		helpers.assert_eq(#timer_spy_calls, 0,
			"modules.llm must stay side-effect free until boot explicitly enables network bootstrap")
		hs_stub.http.__reset()
		for _, call in ipairs(load_time_calls) do call.fire() end
		helpers.assert_eq(#hs_stub.http.__calls, 0,
			"the intentional local API-entry load must not perform backend probes")
	end)

	local required_keys = {
		"llm_enabled", "llm_backend",
		"llm_model_ollama", "llm_model_mlx",
		"llm_debounce", "llm_num_predictions",
		"llm_sequential_mode", "llm_context_length",
		"llm_temperature", "llm_min_words", "llm_max_words",
		"llm_arrow_nav_enabled", "llm_show_info_bar",
		"llm_pred_indent", "llm_active_profile",
		"llm_reset_on_nav", "llm_after_hotstring",
		"llm_auto_raise_temp", "llm_streaming",
		"llm_streaming_multi", "llm_instant_on_word_end",
	}

	for _, k in ipairs(required_keys) do
		helpers.it("contains '" .. k .. "'", function()
			helpers.assert_true(Core.DEFAULT_STATE[k] ~= nil, k .. " is missing")
		end)
	end

	helpers.it("llm_temperature is in [0, 1.5]", function()
		local t = Core.DEFAULT_STATE.llm_temperature
		helpers.assert_true(type(t) == "number" and t >= 0 and t <= 1.5)
	end)

	helpers.it("llm_min_words <= llm_max_words", function()
		helpers.assert_true(Core.DEFAULT_STATE.llm_min_words <= Core.DEFAULT_STATE.llm_max_words)
	end)

	helpers.it("llm_num_predictions is at least 1", function()
		helpers.assert_true(Core.DEFAULT_STATE.llm_num_predictions >= 1)
	end)

	helpers.it("llm_backend is a known identifier", function()
		local b = Core.DEFAULT_STATE.llm_backend
		helpers.assert_true(b == "ollama" or b == "mlx")
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 1c/ explicit network bootstrap =======
-- ==============================================
-- ==============================================

helpers.describe("Core.start_background_network_bootstrap", function()
	helpers.it("primes backend probes only when explicitly called", function()
		local fresh_core, timer_spy_calls, hs_stub = load_core_with_timer_spy()
		hs_stub = package.loaded["hs"]
		hs_stub.http.__reset()
		fresh_core.start_background_network_bootstrap()
		helpers.assert_eq(#timer_spy_calls, 1,
			"explicit bootstrap must schedule exactly one deferred timer")
		helpers.assert_true(timer_spy_calls[1].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4,
			"bootstrap must issue two detection probes and two connection warmups")
	end)

	helpers.it("is idempotent across duplicate calls", function()
		local fresh_core, timer_spy_calls = load_core_with_timer_spy()
		fresh_core.start_background_network_bootstrap()
		fresh_core.start_background_network_bootstrap()
		helpers.assert_eq(#timer_spy_calls, 1,
			"duplicate bootstrap calls must not schedule extra timers")
	end)

	helpers.it("a refused timer does not latch bootstrap as permanently started", function()
		local fresh_core, timer_spy_calls, hs_stub, controller = load_core_with_timer_spy()
		hs_stub.http.__reset()
		controller.fail_next = "settled"
		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)
		helpers.assert_true(fresh_core.start_background_network_bootstrap(),
			"a settled refusal must leave the explicit bootstrap retryable")
		helpers.assert_eq(#timer_spy_calls, 2)
		helpers.assert_true(timer_spy_calls[2].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4)
	end)

	helpers.it("cleanup debt blocks a sibling bootstrap timer until exact retry", function()
		local fresh_core, timer_spy_calls, _, controller = load_core_with_timer_spy()
		controller.fail_next = "debt"
		controller.cancel_failures = 2
		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)

		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)
		helpers.assert_eq(#timer_spy_calls, 1,
			"an activated failed candidate must remain the sole native owner")
		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(#timer_spy_calls, 2)
		end)

	helpers.it("preserves a bootstrap successor installed during native settlement", function()
		local fresh_core, timer_spy_calls, hs_stub, controller = load_core_with_timer_spy()
		hs_stub.http.__reset()
		controller.fail_next = "debt"
		controller.cancel_failures = 1
		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)
		controller.reenter_cancel = function()
			return fresh_core.start_background_network_bootstrap()
		end

		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false,
			"the stale outer transaction must refuse after a nested successor commits")
		helpers.assert_true(controller.reentrant_result)
		helpers.assert_eq(#timer_spy_calls, 2,
			"the outer transaction must not publish a third timer over its successor")
		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(#timer_spy_calls, 2)
		helpers.assert_true(timer_spy_calls[2].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4)
	end)

	helpers.it("preserves an API-load successor installed during native settlement", function()
		local fresh_core, timer_spy_calls, hs_stub, controller, load_time_calls =
			load_core_with_timer_spy({
				initial_fail_next = "debt",
				initial_cancel_failures = 1,
			})
		hs_stub.http.__reset()
		helpers.assert_true(#load_time_calls >= 1)
		controller.reenter_cancel = function()
			return fresh_core.start_background_network_bootstrap()
		end

		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false,
			"the stale API-load transaction must not overwrite its nested successor")
		helpers.assert_true(controller.reentrant_result)
		helpers.assert_eq(#timer_spy_calls, 2,
			"nested API-load and bootstrap owners must remain the only successors")
		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(#timer_spy_calls, 2)
		helpers.assert_true(timer_spy_calls[1].fire())
		helpers.assert_true(timer_spy_calls[2].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4)
	end)

	helpers.it("publishes the background owner before native timer acquisition", function()
		local fresh_core, timer_spy_calls, hs_stub, controller, load_time_calls =
			load_core_with_timer_spy()
		hs_stub.http.__reset()
		helpers.assert_true(load_time_calls[1].fire())
		local nested_result = nil
		controller.reenter_after = function()
			nested_result = fresh_core.start_background_network_bootstrap()
			return nested_result
		end

		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(nested_result, false,
			"a timer start cannot hide a reentrant background successor")
		helpers.assert_eq(#timer_spy_calls, 1,
			"the outer transaction must remain the sole native timer owner")
		helpers.assert_true(timer_spy_calls[1].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4)
	end)

	helpers.it("publishes the API-load owner before a retry acquisition", function()
		local fresh_core, timer_spy_calls, hs_stub, controller, load_time_calls =
			load_core_with_timer_spy({ initial_fail_next = "debt" })
		hs_stub.http.__reset()
		helpers.assert_eq(#load_time_calls, 1)
		local nested_result = nil
		controller.reenter_after = function()
			nested_result = fresh_core.start_background_network_bootstrap()
			return nested_result
		end

		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(nested_result, false,
			"a retrying API-load start cannot publish an invisible sibling")
		helpers.assert_eq(#timer_spy_calls, 2,
			"one API-load retry and one background timer must be owned")
		helpers.assert_true(timer_spy_calls[1].fire())
		helpers.assert_true(timer_spy_calls[2].fire())
		helpers.assert_eq(#hs_stub.http.__calls, 4)
	end)
end)





--- ============================================================
--- ============================================================
--- ======= 1b/ DEFAULT_STATE sourced from defaults.json =======
--- ============================================================
--- ============================================================

-- Regression: the shared scalar defaults must come from _shared/modules/llm/defaults.json
-- (the single source) and never from a hardcoded base table re-declared in
-- init.lua. If a divergent hardcoded value is reintroduced, these comparisons
-- against the JSON fail.
helpers.describe("Core.DEFAULT_STATE single source (defaults.json)", function()
	local json = require("json")
	local path = helpers.shared("modules/llm/defaults.json")
	local fh   = io.open(path, "r")
	local shared = fh and json.decode(fh:read("*a")) or nil
	if fh then fh:close() end

	helpers.it("defaults.json is readable (the required single source)", function()
		helpers.assert_true(type(shared) == "table", "could not read/parse " .. path)
	end)

	if type(shared) == "table" then
		local mirrored = {
			"llm_temperature", "llm_num_predictions", "llm_context_length",
			"llm_min_words", "llm_max_words", "llm_pred_indent",
			"llm_active_profile", "llm_show_info_bar",
		}
		for _, k in ipairs(mirrored) do
			helpers.it(k .. " equals the defaults.json value (not a hardcoded base)", function()
				helpers.assert_eq(Core.DEFAULT_STATE[k], shared[k])
			end)
		end

		helpers.it("llm_debounce derives from defaults.json llm_debounce_ms (ms -> s)", function()
			helpers.assert_eq(Core.DEFAULT_STATE.llm_debounce, shared.llm_debounce_ms / 1000)
		end)
	end
end)




-- =====================================
-- =====================================
-- ======= 2/ Backend Accessors =========
-- =====================================
-- =====================================

helpers.describe("Core.set_backend / get_backend", function()
	helpers.it("get_backend returns the configured default", function()
		local b = Core.get_backend()
		helpers.assert_true(type(b) == "string")
	end)

	helpers.it("set_backend updates the active value", function()
		Core.set_backend("mlx")
		helpers.assert_eq(Core.get_backend(), "mlx")
		Core.set_backend("ollama")
		helpers.assert_eq(Core.get_backend(), "ollama")
	end)

	helpers.it("set_backend ignores empty / non-string", function()
		Core.set_backend("ollama")
		Core.set_backend("")
		helpers.assert_eq(Core.get_backend(), "ollama")
		Core.set_backend(nil)
		helpers.assert_eq(Core.get_backend(), "ollama")
	end)

	for _, boundary in ipairs({ "reset_ready", "ensure_running" }) do
		helpers.it("lets a nested backend successor win during " .. boundary, function()
			local fresh_core = load_core_with_timer_spy()
			helpers.assert_true(fresh_core.set_backend("mlx"))
			local restore_resolver = admit_ollama_start(fresh_core)
			local api = package.loaded["modules.llm.api_ollama"]
			local original_reset = api.reset_ready
			local original_ensure = api.ensure_running
			local reenter = true
			local nested_result = nil
			local ensure_calls = 0
			api.reset_ready = function()
				if boundary == "reset_ready" and reenter then
					reenter = false
					nested_result = fresh_core.set_backend("mlx")
				end
				return true
			end
			api.ensure_running = function()
				ensure_calls = ensure_calls + 1
				if boundary == "ensure_running" and reenter then
					reenter = false
					nested_result = fresh_core.set_backend("mlx")
				end
				return true
			end

			local test_ok, test_error = xpcall(function()
				helpers.assert_eq(fresh_core.set_backend("ollama"), false,
					"the stale outer transition cannot report the successor's identity")
				helpers.assert_true(nested_result)
				helpers.assert_eq(fresh_core.get_backend(), "mlx",
					"the nested backend successor must remain authoritative")
				helpers.assert_eq(ensure_calls,
					boundary == "ensure_running" and 1 or 0,
					"no daemon successor may start after reset-time supersession")
			end, debug.traceback)
			api.reset_ready = original_reset
			api.ensure_running = original_ensure
			restore_resolver()
			if not test_ok then error(test_error, 0) end
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates Ollama daemon startup " .. mode .. " until an exact retry",
			function()
				local fresh_core = load_core_with_timer_spy()
				helpers.assert_true(fresh_core.set_backend("mlx"))
				local restore_resolver = admit_ollama_start(fresh_core)
				local api = package.loaded["modules.llm.api_ollama"]
				local original_ensure = api.ensure_running
				local ensure_calls = 0
				api.ensure_running = function()
					ensure_calls = ensure_calls + 1
					if mode == "throw" then error("daemon startup refusal") end
					if mode == "false" then return false end
					return nil
				end

				local test_ok, test_error = xpcall(function()
					helpers.assert_eq(fresh_core.set_backend("ollama"), false,
						"a daemon startup debt cannot be acknowledged as committed")
					helpers.assert_eq(fresh_core.get_backend(), "ollama",
						"the caller owns compensation for the already-published identity")
					helpers.assert_eq(ensure_calls, 1)

					api.ensure_running = function()
						ensure_calls = ensure_calls + 1
						return true
					end
					helpers.assert_true(fresh_core.set_backend("ollama"),
						"reasserting the same identity must retry the exact startup debt")
					helpers.assert_eq(ensure_calls, 2)
				end, debug.traceback)
				api.ensure_running = original_ensure
				restore_resolver()
				if not test_ok then error(test_error, 0) end
			end)
	end

	helpers.it("lets a nested Ollama model successor win during readiness reset", function()
		local fresh_core = load_core_with_timer_spy()
		helpers.assert_true(fresh_core.set_backend("ollama"))
		helpers.assert_true(fresh_core.set_llm_model_ollama("baseline-model"))
		local api = package.loaded["modules.llm.api_ollama"]
		local original_reset = api.reset_ready
		local reenter = true
		local nested_result = nil
		api.reset_ready = function()
			if reenter then
				reenter = false
				nested_result = fresh_core.set_llm_model_ollama("nested-model")
			end
			return true
		end

		local test_ok, test_error = xpcall(function()
			helpers.assert_eq(fresh_core.set_llm_model_ollama("outer-model"), false)
			helpers.assert_true(nested_result)
			helpers.assert_eq(fresh_core.get_current_model(), "nested-model")
		end, debug.traceback)
		api.reset_ready = original_reset
		if not test_ok then error(test_error, 0) end
	end)
end)
