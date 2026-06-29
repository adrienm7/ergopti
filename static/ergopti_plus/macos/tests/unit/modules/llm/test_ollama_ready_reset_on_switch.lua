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
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
helpers.load_with_stubs("lib.logger")

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
		local fh = assert(io.open(helpers.driver_root() .. "modules/llm/api_ollama.lua", "r"))
		local src = fh:read("*a"); fh:close()
		local idx = src:find("function M.reset_ready", 1, true)
		helpers.assert_true(idx ~= nil, "api_ollama must define M.reset_ready")
		helpers.assert_true(src:find("_is_ready = false", idx, true) ~= nil,
			"reset_ready must clear _is_ready to false")
	end)
end)
