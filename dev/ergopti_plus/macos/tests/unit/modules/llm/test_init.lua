--- tests/unit/modules/llm/test_init.lua

--- ==============================================================================
--- MODULE: llm core (init.lua) Unit Tests
--- DESCRIPTION:
--- Validates the LLM core orchestrator: DEFAULT_STATE shape, profile getter/
--- setter contract, backend selection, and the modifier check helper used by
--- the keystroke routing layer.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- A prior test may have installed a stub modules.llm.profiles (with empty
-- get_all_profiles) that would leak into this file's top-level require.
-- Force the real implementation to be reloaded so profile accessors work.
package.loaded["modules.llm.profiles"]   = nil
package.loaded["llm.profile_selector"]   = nil

local Core = helpers.load_with_stubs("modules.llm")
local INITIAL_HS = _G.hs

local function load_core_with_timer_spy(options)
	options = options or {}
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local timer_spy_calls = {}
	local controller = {
		fail_next = options.initial_fail_next,
		cancel_failures = options.initial_cancel_failures or 0,
		cancel_mode = "true",
	}
	local scheduler_stub = {}
	local function settle_handle(handle)
		handle.committed = false
		handle.fired = true
		handle.timer = nil
		local observers = handle.settlement_observers or {}
		handle.settlement_observers = {}
		for _, observer in ipairs(observers) do observer() end
	end
	function scheduler_stub.after(delay, fn)
		local handle = {
			timer = {},
			committed = false,
			fired = false,
			settlement_observers = {},
		}
		local call = { delay = delay, fn = fn, handle = handle }
		timer_spy_calls[#timer_spy_calls + 1] = call
		function call.fire()
			if handle.committed ~= true or handle.fired then return false end
			settle_handle(handle)
			fn()
			return true
		end
		local reenter = controller.reenter_after
		if type(reenter) == "function" then
			controller.reenter_after = nil
			controller.reentrant_after_result = reenter()
		end
		local failure = controller.fail_next
		controller.fail_next = nil
		if failure == "settled" then
			handle.timer = nil
			handle.fired = true
			return handle, false
		elseif failure == "debt" then
			return handle, false
		end
		handle.committed = true
		return handle, true
	end
	function scheduler_stub.cancel(handle)
		if controller.cancel_mode == "throw" then
			error("profile warmup cancellation refusal")
		end
		if controller.cancel_mode == "false" then return false end
		if controller.cancel_mode == "nil" then return nil end
		if controller.cancel_failures > 0 then
			controller.cancel_failures = controller.cancel_failures - 1
			return false
		end
		local reenter = controller.reenter_cancel
		if type(reenter) == "function" then
			controller.reenter_cancel = nil
			controller.reentrant_result = reenter()
		end
		settle_handle(handle)
		return true
	end
	function scheduler_stub.onSettled(handle, observer)
		if handle.timer == nil then
			observer()
		else
			handle.settlement_observers[#handle.settlement_observers + 1] = observer
		end
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler_stub
	local fresh_core = helpers.load_with_stubs("modules.llm")
	local loaded_hs = package.loaded["hs"]
	local load_time_calls = {}
	for index, call in ipairs(timer_spy_calls) do load_time_calls[index] = call end
	for index = #timer_spy_calls, 1, -1 do timer_spy_calls[index] = nil end
	_G.hs = INITIAL_HS
	return fresh_core, timer_spy_calls, loaded_hs, controller, load_time_calls
end





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
			if not test_ok then error(test_error, 0) end
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates Ollama daemon startup " .. mode .. " until an exact retry",
			function()
				local fresh_core = load_core_with_timer_spy()
				helpers.assert_true(fresh_core.set_backend("mlx"))
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




-- =====================================
-- =====================================
-- ======= 3/ Profile Accessors =========
-- =====================================
-- =====================================

helpers.describe("Core profile accessors", function()
	helpers.it("get_active_profile returns a table with 'id'", function()
		local p = Core.get_active_profile()
		helpers.assert_true(type(p) == "table" and type(p.id) == "string")
	end)

	helpers.it("set_active_profile changes the active id (resolved through Profiles)", function()
		Core.set_active_profile("advanced")
		helpers.assert_eq(Core.get_active_profile().id, "advanced")
	end)

	helpers.it("set_active_profile ignores non-string", function()
		Core.set_active_profile("basic")
		Core.set_active_profile(nil)
		Core.set_active_profile(42)
		helpers.assert_eq(Core.get_active_profile().id, "basic")
	end)

	helpers.it("set_active_profile does not schedule warmup while runtime LLM is disabled", function()
		local fresh_core, scheduled = load_core_with_timer_spy()
		fresh_core.set_runtime_llm_enabled(false)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#scheduled, 0,
			"disabled runtime LLM must not schedule a profile warmup")
	end)

	helpers.it("set_active_profile schedules warmup once runtime LLM is enabled", function()
		local fresh_core, scheduled = load_core_with_timer_spy()
		fresh_core.set_llm_model_ollama("gemma-4-E2B-it")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#scheduled, 1,
			"enabled runtime LLM must schedule exactly one profile warmup")
		helpers.assert_true(fresh_core.pause_deferred_profile_warmup())
		fresh_core.set_runtime_llm_enabled(false)
	end)

	helpers.it("does NOT dispatch the deferred warmup if the backend was switched before it fires (F-MED-6)", function()
		-- Before the fix, set_active_profile's hs.timer.doAfter(0, ...) captured
		-- `model` at profile-set time with no guard: a set_backend() call landing
		-- within the same tick (before the deferred callback runs) would still let
		-- the stale dispatch fire warmup_model(OLD model name) against the NEW
		-- backend. Capture the callback instead of letting it fire immediately so
		-- this test can interleave set_backend() exactly like the real race.
		local fresh_core, captured = load_core_with_timer_spy()

		local warmup_calls = {}
		fresh_core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		fresh_core.set_llm_model_ollama("gemma-4-E2B-it")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_backend("ollama")

		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1, "set_active_profile must schedule exactly one deferred warmup")

		-- Switch backends BEFORE the deferred callback fires — mirrors a user
		-- flipping MLX/Ollama within the same tick as a profile change.
		fresh_core.set_backend("mlx")

		-- Now fire the deferred callback captured earlier.
		captured[1].fire()
		fresh_core.set_runtime_llm_enabled(false)

		helpers.assert_eq(#warmup_calls, 0,
			"a backend switch before the deferred warmup fires must discard the stale dispatch (F-MED-6)")
	end)

	helpers.it("preserves a deferred warmup across a same-backend setter", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end

		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		fresh_core.set_backend("ollama")
		helpers.assert_true(captured[1].fire())
		helpers.assert_eq(warmup_calls, 1,
			"rewriting the same backend must not invalidate a healthy owner")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("blocks backend successors until exact warmup cleanup after " .. mode,
			function()
				local fresh_core, captured, _, controller = load_core_with_timer_spy()
				local warmup_calls = 0
				local ensure_calls = 0
				fresh_core.warmup_model = function()
					warmup_calls = warmup_calls + 1
				end
				helpers.assert_true(fresh_core.set_backend("mlx"))
				fresh_core.set_llm_model_mlx("fixture-model")
				fresh_core.set_runtime_llm_enabled(true)
				fresh_core.set_active_profile("advanced")
				helpers.assert_eq(#captured, 1)
				package.loaded["modules.llm.api_ollama"].ensure_running = function()
					ensure_calls = ensure_calls + 1
					return true
				end

				controller.cancel_mode = mode
				helpers.assert_eq(fresh_core.set_backend("ollama"), false)
				helpers.assert_eq(fresh_core.get_backend(), "mlx",
					"backend publication must wait for exact cleanup")
				helpers.assert_eq(ensure_calls, 0,
					"daemon startup is a forbidden sibling while cleanup is pending")
				helpers.assert_not_nil(captured[1].handle.timer)

				controller.cancel_mode = "true"
				helpers.assert_true(fresh_core.set_backend("ollama"))
				helpers.assert_eq(fresh_core.get_backend(), "ollama")
				helpers.assert_eq(ensure_calls, 1)
				helpers.assert_nil(captured[1].handle.timer)
				captured[1].fn()
				helpers.assert_eq(warmup_calls, 0)
			end)
	end

	for _, case in ipairs({
		{ backend = "ollama", setter = "set_llm_model_ollama" },
		{ backend = "mlx", setter = "set_llm_model_mlx" },
	}) do
		helpers.it("discards a deferred warmup after same-backend " .. case.backend .. " model replacement", function()
			local fresh_core, captured = load_core_with_timer_spy()
			local warmup_calls = 0
			fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end

			fresh_core.set_backend(case.backend)
			fresh_core[case.setter]("fixture-model-a")
			fresh_core.set_runtime_llm_enabled(true)
			fresh_core.set_active_profile("advanced")
			helpers.assert_eq(#captured, 1)

			fresh_core[case.setter]("fixture-model-b")
			captured[1].fn()
			helpers.assert_eq(warmup_calls, 0,
				"a stale profile timer must not warm the predecessor model")
		end)
	end

	for _, case in ipairs({
		{ backend = "ollama", setter = "set_llm_model_ollama", old = "old-ollama" },
		{ backend = "mlx", setter = "set_llm_model_mlx", old = "old-mlx" },
	}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("blocks " .. case.backend .. " model publication after "
				.. mode .. " warmup cleanup", function()
				local fresh_core, captured, _, controller = load_core_with_timer_spy()
				helpers.assert_true(fresh_core.set_backend(case.backend))
				helpers.assert_true(fresh_core[case.setter](case.old))
				fresh_core.set_runtime_llm_enabled(true)
				fresh_core.set_active_profile("advanced")
				helpers.assert_eq(#captured, 1)

				controller.cancel_mode = mode
				helpers.assert_eq(fresh_core[case.setter]("new-model"), false)
				helpers.assert_eq(fresh_core.get_current_model(), case.old,
					"model identity must stay old while exact cleanup is pending")
				helpers.assert_not_nil(captured[1].handle.timer)

				controller.cancel_mode = "true"
				helpers.assert_true(fresh_core[case.setter]("new-model"))
				helpers.assert_eq(fresh_core.get_current_model(), "new-model")
				helpers.assert_nil(captured[1].handle.timer)
				captured[1].fn()
			end)
		end
	end

	helpers.it("discards a deferred warmup across a runtime disable-enable ABA", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end

		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		fresh_core.set_runtime_llm_enabled(false)
		fresh_core.set_runtime_llm_enabled(true)
		captured[1].fn()
		helpers.assert_eq(warmup_calls, 0,
			"re-enabling runtime must not resurrect the pre-disable one-shot")
	end)

	helpers.it("discards a deferred warmup after same-id profile registry replacement", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "Old", system_single = "OLD {context}" },
		})
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("fixture-profile")
		helpers.assert_eq(#captured, 1)

		fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "New", system_single = "NEW {context}" },
		})
		captured[1].fn()
		helpers.assert_eq(warmup_calls, 0,
			"the old profile object must not survive a same-id registry replacement")
	end)

	helpers.it("publishes a profile registry only after prior warmup cleanup settles", function()
		local fresh_core, captured, _, controller = load_core_with_timer_spy()
		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "Old", system_single = "OLD {context}" },
		})
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("fixture-profile")
		helpers.assert_eq(#captured, 1)

		controller.cancel_failures = 1
		helpers.assert_eq(fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "New", system_single = "NEW {context}" },
		}), false)
		helpers.assert_eq(fresh_core.get_active_profile().label, "Old")
		helpers.assert_true(fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "New", system_single = "NEW {context}" },
		}))
		helpers.assert_eq(fresh_core.get_active_profile().label, "New")
	end)

	helpers.it("blocks persisted API restore until prior warmup cleanup settles", function()
		local fresh_core, captured, _, controller = load_core_with_timer_spy()
		local prewarms = 0
		fresh_core.api_remote.prewarm_active_entry_decrypt = function()
			prewarms = prewarms + 1
			return true
		end
		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		controller.cancel_failures = 1
		helpers.assert_eq(fresh_core.load_api_entries(), false)
		helpers.assert_eq(prewarms, 0,
			"remote prewarm is a forbidden sibling while exact timer debt remains")
		helpers.assert_not_nil(captured[1].handle.timer)
		helpers.assert_true(fresh_core.load_api_entries())
		helpers.assert_eq(prewarms, 1)
		helpers.assert_nil(captured[1].handle.timer)
	end)

	helpers.it("discards a deferred API warmup across an active-entry ABA", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		local remote = fresh_core.api_remote
		local entries = {
			{ id = "entry-a", label = "A", provider = "openai", base_url = "https://a.invalid", token = "a", model = "same-model" },
			{ id = "entry-b", label = "B", provider = "openai", base_url = "https://b.invalid", token = "b", model = "same-model" },
		}
		remote.set_entries(entries)
		remote.set_active_entry_id("entry-a")
		fresh_core.set_backend("api")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		remote.set_active_entry_id("entry-b")
		remote.set_active_entry_id("entry-a")
		captured[1].fire()
		helpers.assert_eq(warmup_calls, 0,
			"returning to entry A must not resurrect the pre-switch one-shot")
	end)

	helpers.it("discards a deferred warmup when automatic detection changes backend", function()
		local fresh_core, captured, hs_stub = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		fresh_core.set_llm_model_ollama("fixture-ollama")
		fresh_core.set_llm_model_mlx("fixture-mlx")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		local before = fresh_core.get_backend()
		local mlx_url = require("modules.llm.api_mlx").get_base_url() .. "/v1/models"
		local target
		if before == "ollama" then
			target = "mlx"
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 404, "")
			hs_stub.http.__set_response(mlx_url, 200, '{"object":"list"}')
		else
			target = "ollama"
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 200, '{"version":"fixture"}')
			hs_stub.http.__set_response(mlx_url, 404, "")
		end
		fresh_core.auto_detect_backend()
		helpers.assert_eq(fresh_core.get_backend(), target)

		captured[1].fn()
		helpers.assert_eq(warmup_calls, 0,
			"automatic backend replacement must fence the captured warmup")
	end)

	helpers.it("preserves a deferred warmup when detection confirms the same backend", function()
		local fresh_core, captured, hs_stub = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		fresh_core.set_llm_model_ollama("fixture-ollama")
		fresh_core.set_llm_model_mlx("fixture-mlx")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		local before = fresh_core.get_backend()
		local mlx_url = require("modules.llm.api_mlx").get_base_url() .. "/v1/models"
		if before == "mlx" then
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 404, "")
			hs_stub.http.__set_response(mlx_url, 200, '{"object":"list"}')
		else
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 200, '{"version":"fixture"}')
			hs_stub.http.__set_response(mlx_url, 404, "")
		end
		fresh_core.auto_detect_backend()
		helpers.assert_eq(fresh_core.get_backend(), before)

		helpers.assert_eq(captured[1].fire(), true,
			"same-backend detection must leave the exact timer committed")
		helpers.assert_eq(warmup_calls, 1)
	end)

	helpers.it("retries auto-detect warmup debt on a same-backend confirmation", function()
		local fresh_core, captured, hs_stub, controller = load_core_with_timer_spy()
		local warmup_calls = 0
		local completion_calls = 0
		local ensure_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		fresh_core.set_llm_model_ollama("fixture-ollama")
		fresh_core.set_llm_model_mlx("fixture-mlx")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)

		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end
		local before = fresh_core.get_backend()
		local target = before == "ollama" and "mlx" or "ollama"
		local mlx_url = require("modules.llm.api_mlx").get_base_url() .. "/v1/models"
		if target == "mlx" then
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 404, "")
			hs_stub.http.__set_response(mlx_url, 200, '{"object":"list"}')
		else
			hs_stub.http.__set_response("http://127.0.0.1:11434/api/version", 200, '{"version":"fixture"}')
			hs_stub.http.__set_response(mlx_url, 404, "")
		end
		package.loaded["modules.llm.api_ollama"].ensure_running = function()
			ensure_calls = ensure_calls + 1
			return true
		end
		controller.cancel_failures = 1
		fresh_core.auto_detect_backend(function()
			completion_calls = completion_calls + 1
		end)
		helpers.assert_eq(fresh_core.get_backend(), before,
			"backend publication must wait for exact predecessor settlement")
		helpers.assert_eq(completion_calls, 0,
			"completion must not publish while native cleanup debt remains")
		helpers.assert_eq(ensure_calls, 0,
			"daemon acquisition is a forbidden sibling while cleanup is pending")
		helpers.assert_not_nil(captured[1].handle.timer,
			"the refused exact timer must remain physically owned")

		fresh_core.auto_detect_backend(function()
			completion_calls = completion_calls + 1
		end)
		helpers.assert_nil(captured[1].handle.timer,
			"an explicit retry must bypass the cache and settle the exact debt")
		helpers.assert_eq(fresh_core.get_backend(), target)
		helpers.assert_eq(completion_calls, 1)
		helpers.assert_eq(ensure_calls, target == "ollama" and 1 or 0)
		captured[1].fn()
		helpers.assert_eq(warmup_calls, 0)
	end)

	helpers.it("does NOT dispatch a rejected profile warmup after rollback", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = {}
		fresh_core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		fresh_core.set_llm_model_ollama("gemma-4-E2B-it")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)
		fresh_core.set_active_profile("basic")
		captured[1].fn()

		helpers.assert_true(fresh_core.pause_deferred_profile_warmup())
		fresh_core.set_runtime_llm_enabled(false)
		helpers.assert_eq(#warmup_calls, 0,
			"the rollback profile generation must fence the rejected deferred warmup")
	end)

	helpers.it("(deferred-runtime-gate) does NOT dispatch a deferred profile warmup after runtime disable", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = {}
		fresh_core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("gemma-4-E2B-it")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1,
			"enabled profile change must really own one deferred warmup")
		fresh_core.set_runtime_llm_enabled(false)
		captured[1].fire()

		helpers.assert_eq(#warmup_calls, 0,
			"a timer classified while enabled must re-read the live runtime gate")
	end)

	helpers.it("DOES dispatch the deferred warmup when the backend is unchanged (F-MED-6 control)", function()
		local fresh_core, captured = load_core_with_timer_spy()

		local warmup_calls = {}
		fresh_core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		fresh_core.set_llm_model_ollama("gemma-4-E2B-it")
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_backend("ollama")

		fresh_core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1, "set_active_profile must schedule exactly one deferred warmup")

		-- No backend switch this time — the deferred warmup must proceed normally.
		captured[1].fire()
		fresh_core.set_runtime_llm_enabled(false)

		helpers.assert_eq(#warmup_calls, 1,
			"the deferred warmup must still dispatch when the backend was not switched in between")
	end)

	helpers.it("get_all_profiles includes the four built-ins", function()
		local all = Core.get_all_profiles()
		helpers.assert_true(#all >= 4)
	end)

	helpers.it("set_user_profiles merges user list with built-ins", function()
		local user_profiles = {
			{ id = "myuser", label = "Mine", system_single = "X" },
		}
		helpers.assert_eq(Core.set_user_profiles(user_profiles), true)
		table.insert(user_profiles, {
			id = "second_user", label = "Second", system_single = "Y",
		})
		local all = Core.get_all_profiles()
		local has_user = false
		local has_second = false
		for _, p in ipairs(all) do
			if p.id == "myuser" then has_user = true end
			if p.id == "second_user" then has_second = true end
		end
		helpers.assert_true(has_user)
		helpers.assert_true(has_second,
			"the runtime must retain the exact replacement table, not a detached clone")
		helpers.assert_eq(Core.set_user_profiles({}), true)
	end)

	helpers.it("set_user_profiles rejects non-table input without replacing the registry", function()
		helpers.assert_eq(Core.set_user_profiles({
			{ id = "kept", label = "Kept", system_single = "X" },
		}), true)
		helpers.assert_eq(Core.set_user_profiles("garbage"), false)
		local kept = false
		for _, profile in ipairs(Core.get_all_profiles()) do
			if profile.id == "kept" then kept = true end
		end
		helpers.assert_true(kept, "a refused replacement must preserve the exact registry")
		helpers.assert_eq(Core.set_user_profiles({}), true)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Streaming flag ===========
-- =====================================
-- =====================================

helpers.describe("Core.set_llm_streaming", function()
	helpers.it("accepts boolean true", function()
		Core.set_llm_streaming(true)
	end)

	helpers.it("accepts boolean false", function()
		Core.set_llm_streaming(false)
	end)

	helpers.it("treats non-boolean as false", function()
		Core.set_llm_streaming("yes")
		-- No exception expected
	end)
end)





-- =====================================
-- =====================================
-- ======= 4b/ Cancellation contract ===
-- =====================================
-- =====================================

helpers.describe("Core.cancel_streaming strict backend contract", function()
	helpers.it("propagates true, false, and throw outcomes from the active backend", function()
		local api = package.loaded["modules.llm.api_ollama"]
		helpers.assert_not_nil(api)
		local previous_cancel = api.cancel_streaming
		Core.set_backend("ollama")

		api.cancel_streaming = function() return true end
		helpers.assert_eq(Core.cancel_streaming(), true)
		api.cancel_streaming = function() return false end
		helpers.assert_eq(Core.cancel_streaming(), false)
		api.cancel_streaming = function() error("backend cancel failed") end
		local ok, result = pcall(Core.cancel_streaming)
		helpers.assert_true(ok, "backend cancellation errors must reach the file logger, not escape")
		helpers.assert_eq(result, false)

		api.cancel_streaming = previous_cancel
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ check_modifiers ==========
-- =====================================
-- =====================================

helpers.describe("Core.check_modifiers", function()
	helpers.it("returns false for non-table targetMods", function()
		helpers.assert_eq(Core.check_modifiers({}, nil), false)
		helpers.assert_eq(Core.check_modifiers({}, "alt"), false)
	end)

	helpers.it("returns false for {'none'}", function()
		helpers.assert_eq(Core.check_modifiers({}, { "none" }), false)
	end)

	helpers.it("matches a single modifier exactly", function()
		helpers.assert_eq(Core.check_modifiers({ alt = true }, { "alt" }), true)
		helpers.assert_eq(Core.check_modifiers({ alt = false }, { "alt" }), false)
	end)

	helpers.it("rejects when extra modifiers are pressed", function()
		-- Target alt, but cmd is also held
		helpers.assert_eq(Core.check_modifiers({ alt = true, cmd = true }, { "alt" }), false)
	end)

	helpers.it("matches multi-modifier sets exactly", function()
		helpers.assert_eq(
			Core.check_modifiers({ cmd = true, shift = true }, { "cmd", "shift" }),
			true
		)
		helpers.assert_eq(
			Core.check_modifiers({ cmd = true, shift = false }, { "cmd", "shift" }),
			false
		)
	end)

	helpers.it("returns false when expected modifier is missing", function()
		helpers.assert_eq(Core.check_modifiers({}, { "alt" }), false)
	end)
end)




-- =========================================
-- =========================================
-- ======= 6/ Model setters =================
-- =========================================
-- =========================================

helpers.describe("Core model setters", function()
	helpers.it("set_llm_model_ollama accepts strings", function()
		Core.set_llm_model_ollama("foo:bar")
	end)

	helpers.it("set_llm_model_mlx accepts strings", function()
		Core.set_llm_model_mlx("foo-mlx")
	end)

	helpers.it("get_current_model returns a string", function()
		helpers.assert_eq(type(Core.get_current_model()), "string")
	end)
end)
