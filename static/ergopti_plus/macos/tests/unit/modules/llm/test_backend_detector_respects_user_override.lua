--- tests/unit/modules/llm/test_backend_detector_respects_user_override.lua

--- ==============================================================================
--- MODULE: llm.init — set_backend() override regression test
--- DESCRIPTION:
--- Regression guard for the detection-generation mechanism in modules.llm.init:
--- verifies that auto_detect_backend() does not overwrite CoreState.backend when
--- set_backend() is called while HTTP probes are still in-flight.
---
--- RATIONALE:
--- auto_detect_backend() is async. Before launching HTTP probes it snapshots
--- CoreState.detection_generation into a closure-local `my_generation`. When both
--- probes complete, on_both_done() compares that snapshot against the live counter;
--- if set_backend() was called in the meantime it will have bumped the counter,
--- making the snapshot stale — so the probe result is discarded. This test
--- encodes that invariant so the mechanism can never silently regress.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Minimal no-op stub for a backend API module (api_ollama, api_mlx, api_remote).
--- Only the methods referenced in modules.llm.init need to exist.
--- @return table A stub API module.
local function make_api_stub()
	return {
		get_base_url          = function() return "http://127.0.0.1:18888" end,
		warmup                = function() end,
		cancel_streaming      = function() end,
		is_ready              = function() return false end,
		is_load_failed        = function() return false end,
		is_thinking_model     = function() return false end,
		check_availability    = function() end,
		fetch_batch           = function() end,
		fetch_parallel        = function() end,
		fetch_sequential      = function() end,
		get_active_entry      = function() return nil end,
		get_active_entry_id   = function() return "" end,
		get_entries           = function() return {} end,
		set_entries           = function() end,
		set_active_entry_id   = function() end,
	}
end

--- Minimal stub for modules.llm.profiles — only the surface called at require
--- time and during auto_detect_backend / set_backend execution.
--- @return table A stub profiles module.
local function make_profiles_stub()
	return {
		BUILTIN_PROFILES = {},
		get_active_profile = function(_, _)
			return { id = "raw", batch = false }
		end,
		get_all_profiles = function(_) return {} end,
	}
end

--- Loads a fresh copy of modules.llm.init with all heavy sub-modules pre-stubbed
--- and hs.http.asyncGet replaced with a deferred implementation that captures
--- callbacks without firing them. Returns the module and a fire_probes trigger.
---
--- @param ollama_status number HTTP status code for the Ollama probe.
--- @param ollama_body   string HTTP body for the Ollama probe.
--- @param mlx_status    number HTTP status code for the MLX probe.
--- @param mlx_body      string HTTP body for the MLX probe.
--- @return table, function The loaded module and the fire_probes trigger.
local function load_llm_init_with_deferred_probes(ollama_status, ollama_body, mlx_status, mlx_body)
	-- Wipe the real module and all its transitive dependencies so this helper
	-- can be called multiple times within the same process without state leaks
	local keys_to_clear = {
		"modules.llm.init",
		"modules.llm.profiles",
		"modules.llm.api_ollama",
		"modules.llm.api_mlx",
		"modules.llm.api_remote",
		"modules.llm.api_token_crypto",
		"modules.llm.api_common",
		"modules.llm.parser",
		"adapters.http_client",
		"adapters.json_codec",
		"adapters.timer_scheduler",
		"adapters.shell_runner",
		"lib.logger",
		"lib.notifications",
		"lib.paths",
		"lib.i18n",
		"hs",
		"tests.stubs.hs",
	}
	for _, key in ipairs(keys_to_clear) do
		package.loaded[key] = nil
	end

	-- Fresh hs stub
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	-- Standard stubs (mirror what load_with_stubs injects)
	package.loaded["lib.i18n"] = {
		get        = function(key) return key end,
		get_locale = function() return "fr" end,
		set_locale = function() end,
	}
	package.loaded["lib.paths"] = {
		shared = function(rel) return helpers.shared(rel) end,
		shared_root = function() return helpers.shared() end,
		shared_llm_path = function(name)
			return helpers.shared("modules/llm/" .. name)
		end,
		find_from_configdir = function(relative_target)
			return helpers.driver_root() .. "../../" .. relative_target
		end,
	}
	package.loaded["lib.notifications"] = {
		send  = function() end,
		error = function() end,
	}

	-- Pre-stub all sub-modules so modules.llm.init does not trigger their real
	-- require chains (which would pull in adapters, shared Lua libs, etc.)
	package.loaded["modules.llm.profiles"]          = make_profiles_stub()
	package.loaded["modules.llm.api_ollama"]        = make_api_stub()
	package.loaded["modules.llm.api_token_crypto"]  = {
		encrypt = function(_, t) return t end,
		decrypt = function(t) return t end,
	}

	-- api_mlx stub: get_base_url() is called at init.lua require-time to build
	-- the MLX probe URL — it must return a deterministic string
	local mlx_stub = make_api_stub()
	mlx_stub.get_base_url = function() return "http://127.0.0.1:18888" end
	package.loaded["modules.llm.api_mlx"] = mlx_stub

	package.loaded["modules.llm.api_remote"] = make_api_stub()

	-- Replace asyncGet with a deferred version that captures callbacks for
	-- manual firing instead of invoking them inline
	local pending_gets = {}
	hs_stub.http.asyncGet = function(url, headers, callback)
		pending_gets[#pending_gets + 1] = { url = url, headers = headers, callback = callback }
	end

	-- Load the real modules.llm.init — load_shared_defaults() runs now, reading
	-- _shared/modules/llm/defaults.json via lib.paths stub (requires lib.paths to be set
	-- before this line)
	local LLM = require("modules.llm.init")

	-- Build the fire_probes closure that delivers HTTP responses to the captured
	-- callbacks, simulating the deferred completion of the async probes
	local function fire_probes()
		for _, req in ipairs(pending_gets) do
			if type(req.callback) == "function" then
				-- Discriminate by URL: Ollama listens on port 11434; anything
				-- else is treated as the MLX probe
				if req.url:find("11434") then
					req.callback(ollama_status, ollama_body, {})
				else
					req.callback(mlx_status, mlx_body, {})
				end
			end
		end
	end

	return LLM, fire_probes
end

--- Loads a fresh copy of modules.llm.init with hs.http.asyncGet REPLACED so it
--- throws synchronously for the leg identified by `throw_on_url_substr` (e.g.
--- "11434" for Ollama, anything else for MLX), and completes normally for the
--- other leg via the deferred-callback mechanism above.
--- @param throw_on_url_substr string Substring identifying which probe's URL must throw.
--- @param other_status number HTTP status for the OTHER (non-throwing) leg.
--- @param other_body   string HTTP body for the OTHER (non-throwing) leg.
--- @return table, function The loaded module and the fire_probes trigger (fires only the surviving leg).
local function load_llm_init_with_one_leg_throwing(throw_on_url_substr, other_status, other_body)
	local LLM, fire_probes -- forward-declared; overwritten below with a throwing asyncGet
	local keys_to_clear = {
		"modules.llm.init", "modules.llm.profiles", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.api_remote", "modules.llm.api_token_crypto",
		"modules.llm.api_common", "modules.llm.parser", "adapters.http_client",
		"adapters.json_codec", "adapters.timer_scheduler", "adapters.shell_runner",
		"lib.logger", "lib.notifications", "lib.paths", "lib.i18n", "hs", "tests.stubs.hs",
	}
	for _, key in ipairs(keys_to_clear) do package.loaded[key] = nil end

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	package.loaded["lib.i18n"] = {
		get        = function(key) return key end,
		get_locale = function() return "fr" end,
		set_locale = function() end,
	}
	package.loaded["lib.paths"] = {
		shared = function(rel) return helpers.shared(rel) end,
		shared_root = function() return helpers.shared() end,
		shared_llm_path = function(name) return helpers.shared("modules/llm/" .. name) end,
		find_from_configdir = function(relative_target)
			return helpers.driver_root() .. "../../" .. relative_target
		end,
	}
	package.loaded["lib.notifications"] = { send = function() end, error = function() end }

	package.loaded["modules.llm.profiles"]         = make_profiles_stub()
	package.loaded["modules.llm.api_ollama"]       = make_api_stub()
	package.loaded["modules.llm.api_token_crypto"] = {
		encrypt = function(_, t) return t end,
		decrypt = function(t) return t end,
	}
	local mlx_stub = make_api_stub()
	mlx_stub.get_base_url = function() return "http://127.0.0.1:18888" end
	package.loaded["modules.llm.api_mlx"]    = mlx_stub
	package.loaded["modules.llm.api_remote"] = make_api_stub()

	local pending_gets = {}
	hs_stub.http.asyncGet = function(url, _headers, callback)
		if url:find(throw_on_url_substr, 1, true) then
			error("synchronous throw simulating a malformed URL / transport failure")
		end
		pending_gets[#pending_gets + 1] = { url = url, callback = callback }
	end

	LLM = require("modules.llm.init")

	fire_probes = function()
		for _, req in ipairs(pending_gets) do
			if type(req.callback) == "function" then req.callback(other_status, other_body, {}) end
		end
	end

	return LLM, fire_probes
end





-- ===================================================================
-- ===================================================================
-- ======= 1/ set_backend() override survives probe completion =======
-- ===================================================================
-- ===================================================================

helpers.describe("llm.init — set_backend() override survives probe completion", function()

	helpers.it("backend stays 'api' when set_backend called while probes are in-flight", function()
		-- Probes will report Ollama healthy — without the generation guard this
		-- would overwrite the user'choice back to 'ollama'
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',   -- Ollama: healthy
			200, '{"object":"list"}'       -- MLX: healthy
		)

		-- Step 1: launch auto-detect — probes are now in-flight (callbacks deferred)
		LLM.auto_detect_backend()

		-- Step 2: explicit user override while probes have not completed yet
		LLM.set_backend("api")

		-- Sanity: the override must be visible immediately
		helpers.assert_eq(LLM.get_backend(), "api",
			"get_backend() should return 'api' right after set_backend('api')")

		-- Step 3: simulate the async HTTP responses arriving
		fire_probes()

		-- Step 4: the user override must be preserved — the stale probe discarded
		helpers.assert_eq(LLM.get_backend(), "api",
			"probe result must not overwrite the explicit set_backend() call")
	end)


	helpers.it("backend is updated by probe when no override was made", function()
		-- Control case: without a set_backend() call the probe result IS applied
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',   -- Ollama: healthy
			404, ""                        -- MLX: not available
		)

		LLM.auto_detect_backend()

		-- No set_backend() call — the probe result must be applied
		fire_probes()

		-- Ollama was the only healthy backend so detection must select it
		helpers.assert_eq(LLM.get_backend(), "ollama",
			"probe result should update backend when no user override occurred")
	end)


	helpers.it("backend stays 'mlx' when set_backend('mlx') overrides an ollama-detecting probe", function()
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',   -- Ollama: healthy
			200, '{"object":"list"}'       -- MLX: healthy (ollama wins on tie without override)
		)

		LLM.auto_detect_backend()

		-- User explicitly picks MLX while probes are still pending
		LLM.set_backend("mlx")

		fire_probes()

		helpers.assert_eq(LLM.get_backend(), "mlx",
			"probe result must not overwrite explicit 'mlx' override even when ollama is preferred by detector")
	end)


	helpers.it("last set_backend call wins when called twice before probes complete", function()
		-- Two back-to-back set_backend() calls each bump detection_generation,
		-- so any prior auto_detect probe is doubly stale and still discarded
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',
			200, '{"object":"list"}'
		)

		LLM.auto_detect_backend()
		LLM.set_backend("mlx")
		LLM.set_backend("api")   -- Second override supersedes the first

		fire_probes()

		helpers.assert_eq(LLM.get_backend(), "api",
			"last set_backend() call wins; stale probe must not overwrite it")
	end)


	helpers.it("set_backend with empty string is a no-op — prior valid override is preserved", function()
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',
			200, '{"object":"list"}'
		)

		LLM.auto_detect_backend()
		LLM.set_backend("api")
		-- Empty string must be rejected by the guard in set_backend(); the
		-- detection_generation must not be bumped a second time, but the
		-- prior valid call already made the probe stale — override survives
		LLM.set_backend("")

		fire_probes()

		helpers.assert_eq(LLM.get_backend(), "api",
			"empty-string set_backend must be ignored; prior valid override must survive")
	end)


	helpers.it("user_override_backend flag blocks a SUBSEQUENT auto_detect call after set_backend", function()
		-- H-12 fix (user_override_backend flag): a NEW auto_detect_backend() call
		-- launched AFTER set_backend() must also be blocked, not just in-flight probes.
		-- Without the flag, a background timer calling auto_detect again would silently
		-- overwrite the manual choice once the new probes completed.
		local LLM, fire_probes = load_llm_init_with_deferred_probes(
			200, '{"version":"0.5.0"}',   -- Ollama: healthy
			404, ""                        -- MLX: not available
		)

		-- User explicitly sets the backend before any auto-detect
		LLM.set_backend("api")

		-- A new auto_detect call fires AFTER the manual choice (e.g. background poll)
		LLM.auto_detect_backend()
		fire_probes()

		-- The user_override_backend flag must have prevented the probe from writing
		helpers.assert_eq(LLM.get_backend(), "api",
			"user_override_backend flag must block a subsequent auto_detect from overwriting the manual choice")
	end)

end)




-- ========================================================================
-- ========================================================================
-- ======= 2/ auto_detect_backend survives a synchronous throw (F-MED-5) =
-- ========================================================================
-- ========================================================================

helpers.describe("llm.init — auto_detect_backend survives a synchronous asyncGet throw (F-MED-5)", function()

	helpers.it("completes detection when the Ollama leg throws synchronously", function()
		-- Before the fix, pcall(hs.http.asyncGet, ...)'s boolean result was
		-- discarded: a synchronous throw left ollama_done stuck at false forever,
		-- so on_both_done() never fired and the callback was silently dropped.
		local LLM, fire_mlx_leg = load_llm_init_with_one_leg_throwing(
			"11434",                  -- Ollama leg throws
			200, '{"object":"list"}'  -- MLX leg: healthy
		)

		local callback_fired = false
		local reported_backend = nil
		LLM.auto_detect_backend(function(backend)
			callback_fired = true
			reported_backend = backend
		end)

		-- Deliver the surviving (MLX) leg's response — the Ollama leg already
		-- "completed" (as a failure) synchronously inside auto_detect_backend.
		fire_mlx_leg()

		helpers.assert_true(callback_fired,
			"auto_detect_backend's callback must still fire after one leg throws synchronously (F-MED-5)")
		helpers.assert_eq(reported_backend, "mlx",
			"with Ollama failed and MLX healthy, detection must resolve to mlx")
		helpers.assert_eq(LLM.get_backend(), "mlx",
			"CoreState.backend must be updated even though one probe leg threw synchronously")
	end)

	helpers.it("completes detection when the MLX leg throws synchronously", function()
		local LLM, fire_ollama_leg = load_llm_init_with_one_leg_throwing(
			"18888",                     -- MLX leg throws (matches the stubbed get_base_url())
			200, '{"version":"0.5.0"}'   -- Ollama leg: healthy
		)

		local callback_fired = false
		local reported_backend = nil
		LLM.auto_detect_backend(function(backend)
			callback_fired = true
			reported_backend = backend
		end)

		fire_ollama_leg()

		helpers.assert_true(callback_fired,
			"auto_detect_backend's callback must still fire after the MLX leg throws synchronously (F-MED-5)")
		helpers.assert_eq(reported_backend, "ollama",
			"with MLX failed and Ollama healthy, detection must resolve to ollama")
		helpers.assert_eq(LLM.get_backend(), "ollama",
			"CoreState.backend must be updated even though the MLX probe leg threw synchronously")
	end)

end)
