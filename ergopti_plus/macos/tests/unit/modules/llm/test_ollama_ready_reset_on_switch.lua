--- tests/unit/modules/llm/test_ollama_ready_reset_on_switch.lua

--- ==============================================================================
--- MODULE: Regression — ApiOllama readiness is reset on backend / model switch
--- DESCRIPTION:
--- Audit finding F-M8. ApiOllama._is_ready was only ever set true by a 200 warmup
--- and never reset. A backend round-trip (MLX kills `ollama serve`, then back to
--- Ollama) or a model switch left it stale-true, so the warmup retry chain
--- self-terminated ("backend already ready") and perform_check dispatched to a
--- cold/dead server with no automatic recovery. Unlike ApiMlx (reset_endpoints)
--- and ApiRemote (re-ping), ApiOllama exposed no reset hook.
---
--- Fix: ApiOllama.reset_ready() clears the flag, and core_llm.set_backend() +
--- set_llm_model_ollama() call it on every (server, model) identity change.
---
--- SECOND HALF OF THE FIX (generation guard). Clearing the flag is not enough on
--- its own: an Ollama warmup POST triggers the actual model load and can stay in
--- flight for tens of seconds, so a response for the PREVIOUS server can land
--- after reset_ready() and flip _is_ready back to true. warmup_controller
--- .try_warmup then sees a ready backend, logs "Backend ready — stopping retry
--- chain" and TERMINATES: no warmup ever runs again for the session and every
--- later prediction goes to a server that is not listening.
---
--- The MLX twin was hardened for exactly this (api_mlx.lua: `local my_warmup_gen
--- = _warmup_gen` + the stale comparison in the callback). Ollama had received
--- only the reset_ready half. api_ollama now mirrors the MLX pattern: a module
--- level _warmup_gen bumped by reset_ready(), captured in M.warmup() before the
--- POST, and compared as the FIRST statement of the response callback.
---
--- Sections 1-2 assert only that reset_ready is CALLED and that it clears the
--- flag — they never model the late callback, so they were a FALSE GREEN for the
--- race itself. Section 3 drives it directly.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

helpers.describe("core_llm resets Ollama readiness on every switch", function()
	helpers.it("set_backend and set_llm_model_ollama call ApiOllama.reset_ready", function()
		local reset_calls = 0
		-- Stub ApiOllama BEFORE loading the core so we observe the reset wiring.
		package.loaded["modules.llm.api_ollama"] = {
			reset_ready    = function() reset_calls = reset_calls + 1 end,
			ensure_running = function() end,
			is_ready       = function() return false end,
			warmup         = function() end,
		}

		local Core = helpers.load_with_stubs("modules.llm")

		Core.set_backend("mlx")       -- leaving Ollama must reset its readiness
		Core.set_backend("ollama")    -- returning relaunches async, not yet ready
		helpers.assert_true(reset_calls >= 2,
			"set_backend must reset Ollama readiness on each transition")

		local before = reset_calls
		Core.set_llm_model_ollama("some-other-model")
		helpers.assert_true(reset_calls > before,
			"set_llm_model_ollama must reset readiness so the new model re-warms")

		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm"]            = nil
	end)
end)

helpers.describe("ApiOllama.reset_ready clears the flag", function()
	helpers.it("source: reset_ready sets _is_ready = false", function()
		-- Selected by a declaration unique to modules/llm/api_ollama.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_ollama_port_override")
		helpers.assert_true(src ~= nil, "modules/llm/api_ollama.lua source must be locatable")
		local idx = src:find("function M.reset_ready", 1, true)
		helpers.assert_true(idx ~= nil, "api_ollama must define M.reset_ready")
		helpers.assert_true(src:find("_is_ready = false", idx, true) ~= nil,
			"reset_ready must clear _is_ready to false")
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 3/ Late Warmup Callback Is Discarded =======
-- ====================================================
-- ====================================================

-- The behavioural half. The http client is stubbed so post() CAPTURES its
-- callback instead of invoking it, which models the real timing: the POST is
-- still in flight while the user switches backend away and back.

helpers.describe("ApiOllama — a stale warmup 200 must not resurrect readiness", function()
	helpers.it("a warmup response that lands after reset_ready() is discarded", function()
		local saved_http   = package.loaded["adapters.http_client"]
		local saved_notify = package.loaded["infra.notifications"]
		local saved_api    = package.loaded["modules.llm.api_ollama"]

		-- Capture the callback rather than invoking it: the warmup POST for model-a
		-- is still in flight when the backend round-trip happens.
		local captured_cb = nil
		local post_count  = 0
		package.loaded["adapters.http_client"] = {
			new = function()
				return {
					post = function(_url, _headers, _payload, cb)
						post_count  = post_count + 1
						captured_cb = cb
					end,
					get      = function(_url, _headers, cb) if cb then cb({ ok = false, status = 0, body = "" }) end end,
					cancel   = function() end,
					isActive = function() return false end,
				}
			end,
		}

		-- A stale 200 must not fire the user-facing "server ready" notification either.
		local notify_count = 0
		package.loaded["infra.notifications"] = { notify = function() notify_count = notify_count + 1 end }

		package.loaded["modules.llm.api_ollama"] = nil
		local ApiOllama = require("modules.llm.api_ollama")

		-- Warmup for model-a goes out and stays in flight
		ApiOllama.warmup("model-a")

		-- The user switches backend to MLX and back: core_llm.set_backend calls
		-- reset_ready() on both transitions, and the MLX detour kills `ollama serve`
		ApiOllama.reset_ready()

		-- Only now does model-a's POST resolve — against a server that was killed
		if captured_cb then captured_cb({ status = 200, body = "{}" }) end

		local observed_ready  = ApiOllama.is_ready()
		local observed_notify = notify_count
		local observed_posts  = post_count

		package.loaded["adapters.http_client"]   = saved_http
		package.loaded["infra.notifications"]      = saved_notify
		package.loaded["modules.llm.api_ollama"] = saved_api

		-- Arrangement guard: if the POST never went out (or the callback was never
		-- captured) the readiness assertion below would pass for the wrong reason.
		helpers.assert_eq(observed_posts, 1,
			"warmup must have issued exactly one POST and handed us its callback — otherwise this case proves nothing")

		helpers.assert_true(observed_ready == false,
			"a warmup 200 that lands AFTER reset_ready() describes a server that was just killed — flipping _is_ready " ..
			"back to true makes warmup_controller.try_warmup see a ready backend, stop the retry chain, and send every " ..
			"later prediction to a server that is not listening, with no recovery for the session (F-M8 / F-L4)")
		helpers.assert_eq(observed_notify, 0,
			"a discarded stale warmup must not fire the user-facing 'server ready' notification")
	end)
end)
