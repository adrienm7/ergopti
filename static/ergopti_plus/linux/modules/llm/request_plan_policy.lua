--- modules/llm/request_plan_policy.lua

--- ==============================================================================
--- MODULE: Prediction Request Plan Policy (Linux)
--- DESCRIPTION:
--- The choices Linux makes where the shared request plan
--- (_shared/lua/llm/request_plan) leaves a driver option, and the factory that
--- builds the engine's plan from the backend floor. The corpus
--- _shared/tests/corpus/llm/request_plan_debounce_vectors.json declares the same
--- table under driver_options.linux and the contract test compares the two.
---
--- FEATURES & RATIONALE:
--- 1. "Never" (the shared debounce sentinel, -1) turns the automatic trigger off,
---    so the plan accepts a negative debounce.
--- 2. Only an automatic request waits for the backend's interval. An explicit one
---    (a shortcut, a typed trigger, a prompt action) is never held, and neither
---    are the later variants of its sequential run (maintainer, 2026-10-26).
--- 3. The last request time is kept per backend kind, because the agent, tone and
---    screen requests share the same map.
--- 4. A word end fires instantly in live mode too (when the instant word end
---    is on), as on macOS and Windows.
--- ==============================================================================

local M = {}

local Debounce = require("llm.request_plan.debounce")

-- The option set this driver runs; compared with the corpus by the contract test.
M.OPTIONS = {
	allow_never = true,
	floor_scope = "per_backend",
	live_instant_word_end = true,
}

--- Builds the engine's plan.
--- @param floor_ms function Milliseconds of minimum interval for a backend id.
--- @return table plan
function M.new(floor_ms)
	local options = { floor_ms = floor_ms }
	for key, value in pairs(M.OPTIONS) do options[key] = value end
	return Debounce.new(options)
end

return M
