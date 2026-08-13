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

local function load_core_with_timer_spy()
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local timer_spy_calls = {}
	local controller = { fail_next = nil, cancel_failures = 0 }
	local scheduler_stub = {}
	function scheduler_stub.after(delay, fn)
		local handle = { timer = {}, committed = false, fired = false }
		local call = { delay = delay, fn = fn, handle = handle }
		timer_spy_calls[#timer_spy_calls + 1] = call
		function call.fire()
			if handle.committed ~= true or handle.fired then return false end
			handle.committed = false
			handle.fired = true
			handle.timer = nil
			fn()
			return true
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
		if controller.cancel_failures > 0 then
			controller.cancel_failures = controller.cancel_failures - 1
			return false
		end
		handle.committed = false
		handle.fired = true
		handle.timer = nil
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
		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)

		controller.cancel_failures = 1
		helpers.assert_eq(fresh_core.start_background_network_bootstrap(), false)
		helpers.assert_eq(#timer_spy_calls, 1,
			"an activated failed candidate must remain the sole native owner")
		helpers.assert_true(fresh_core.start_background_network_bootstrap())
		helpers.assert_eq(#timer_spy_calls, 2)
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
		local scheduled = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			scheduled[#scheduled + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end
		Core.set_runtime_llm_enabled(false)
		Core.set_active_profile("advanced")
		hs.timer.doAfter = old_do_after
		helpers.assert_eq(#scheduled, 0,
			"disabled runtime LLM must not schedule a profile warmup")
	end)

	helpers.it("set_active_profile schedules warmup once runtime LLM is enabled", function()
		local scheduled = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			scheduled[#scheduled + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end
		Core.set_llm_model_ollama("gemma-4-E2B-it")
		Core.set_runtime_llm_enabled(true)
		Core.set_active_profile("advanced")
		hs.timer.doAfter = old_do_after
		helpers.assert_eq(#scheduled, 1,
			"enabled runtime LLM must schedule exactly one profile warmup")
		Core.set_runtime_llm_enabled(false)
	end)

	helpers.it("does NOT dispatch the deferred warmup if the backend was switched before it fires (F-MED-6)", function()
		-- Before the fix, set_active_profile's hs.timer.doAfter(0, ...) captured
		-- `model` at profile-set time with no guard: a set_backend() call landing
		-- within the same tick (before the deferred callback runs) would still let
		-- the stale dispatch fire warmup_model(OLD model name) against the NEW
		-- backend. Capture the callback instead of letting it fire immediately so
		-- this test can interleave set_backend() exactly like the real race.
		local captured = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			captured[#captured + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end

		local warmup_calls = {}
		local old_warmup_model = Core.warmup_model
		Core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		Core.set_llm_model_ollama("gemma-4-E2B-it")
		Core.set_runtime_llm_enabled(true)
		Core.set_backend("ollama")
		captured = {}  -- discard the doAfter(s) triggered by the setup above

		Core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1, "set_active_profile must schedule exactly one deferred warmup")

		-- Switch backends BEFORE the deferred callback fires — mirrors a user
		-- flipping MLX/Ollama within the same tick as a profile change.
		Core.set_backend("mlx")

		-- Now fire the deferred callback captured earlier.
		captured[1].fn()

		hs.timer.doAfter   = old_do_after
		Core.warmup_model  = old_warmup_model
		Core.set_runtime_llm_enabled(false)

		helpers.assert_eq(#warmup_calls, 0,
			"a backend switch before the deferred warmup fires must discard the stale dispatch (F-MED-6)")
	end)

	helpers.it("does NOT dispatch a rejected profile warmup after rollback", function()
		local captured = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			captured[#captured + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end
		local warmup_calls = {}
		local old_warmup_model = Core.warmup_model
		Core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		Core.set_llm_model_ollama("gemma-4-E2B-it")
		Core.set_runtime_llm_enabled(true)
		Core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1)
		Core.set_active_profile("basic")
		captured[1].fn()

		hs.timer.doAfter = old_do_after
		Core.warmup_model = old_warmup_model
		Core.set_runtime_llm_enabled(false)
		helpers.assert_eq(#warmup_calls, 0,
			"the rollback profile generation must fence the rejected deferred warmup")
	end)

	helpers.it("(deferred-runtime-gate) does NOT dispatch a deferred profile warmup after runtime disable", function()
		local captured = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			captured[#captured + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end
		local warmup_calls = {}
		local old_warmup_model = Core.warmup_model
		Core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		Core.set_backend("ollama")
		Core.set_llm_model_ollama("gemma-4-E2B-it")
		Core.set_runtime_llm_enabled(true)
		Core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1,
			"enabled profile change must really own one deferred warmup")
		Core.set_runtime_llm_enabled(false)
		captured[1].fn()

		hs.timer.doAfter = old_do_after
		Core.warmup_model = old_warmup_model
		helpers.assert_eq(#warmup_calls, 0,
			"a timer classified while enabled must re-read the live runtime gate")
	end)

	helpers.it("DOES dispatch the deferred warmup when the backend is unchanged (F-MED-6 control)", function()
		local captured = {}
		local old_do_after = hs.timer.doAfter
		hs.timer.doAfter = function(delay, fn)
			captured[#captured + 1] = { delay = delay, fn = fn }
			return { stop = function() end }
		end

		local warmup_calls = {}
		local old_warmup_model = Core.warmup_model
		Core.warmup_model = function(model_name, profile)
			warmup_calls[#warmup_calls + 1] = { model = model_name, profile = profile }
		end

		Core.set_llm_model_ollama("gemma-4-E2B-it")
		Core.set_runtime_llm_enabled(true)
		Core.set_backend("ollama")
		captured = {}

		Core.set_active_profile("advanced")
		helpers.assert_eq(#captured, 1, "set_active_profile must schedule exactly one deferred warmup")

		-- No backend switch this time — the deferred warmup must proceed normally.
		captured[1].fn()

		hs.timer.doAfter  = old_do_after
		Core.warmup_model = old_warmup_model
		Core.set_runtime_llm_enabled(false)

		helpers.assert_eq(#warmup_calls, 1,
			"the deferred warmup must still dispatch when the backend was not switched in between")
	end)

	helpers.it("get_all_profiles includes the four built-ins", function()
		local all = Core.get_all_profiles()
		helpers.assert_true(#all >= 4)
	end)

	helpers.it("set_user_profiles merges user list with built-ins", function()
		Core.set_user_profiles({ { id = "myuser", label = "Mine", system_single = "X" } })
		local all = Core.get_all_profiles()
		local has_user = false
		for _, p in ipairs(all) do if p.id == "myuser" then has_user = true end end
		helpers.assert_true(has_user)
	end)

	helpers.it("set_user_profiles ignores non-table input", function()
		Core.set_user_profiles({})
		Core.set_user_profiles("garbage")
		-- Should not crash
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
