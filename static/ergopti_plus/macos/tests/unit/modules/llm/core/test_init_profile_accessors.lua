--- tests/unit/modules/llm/core/test_init_profile_accessors.lua

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
				local restore_resolver = admit_ollama_start(fresh_core)
				local test_ok, test_error = xpcall(function()
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
				end, debug.traceback)
				restore_resolver()
				if not test_ok then error(test_error, 0) end
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

	helpers.it("preserves queued warmup after malformed profile registry refusal", function()
		local fresh_core, captured = load_core_with_timer_spy()
		local warmup_calls = 0
		fresh_core.warmup_model = function() warmup_calls = warmup_calls + 1 end
		fresh_core.set_backend("ollama")
		fresh_core.set_llm_model_ollama("fixture-model")
		helpers.assert_eq(fresh_core.set_user_profiles({
			{ id = "fixture-profile", label = "Old", system_single = "OLD {context}" },
		}), true)
		fresh_core.set_runtime_llm_enabled(true)
		fresh_core.set_active_profile("fixture-profile")
		helpers.assert_eq(#captured, 1)
		helpers.assert_eq(fresh_core.set_user_profiles({ false }), false)
		helpers.assert_eq(fresh_core.set_user_profiles({ { id = 0 / 0 } }), false)
		helpers.assert_eq(fresh_core.get_active_profile().label, "Old")
		helpers.assert_eq(captured[1].fire(), true, "refusal must not cancel prior warmup")
		helpers.assert_eq(warmup_calls, 1)
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
