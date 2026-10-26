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
--- 1. The debounce menu has a 50 ms minimum, so there is no "never" here.
--- 2. Every request waits for the backend's interval, explicit ones and the next
---    variants of a sequential request included: a hosted API with a free tier
---    answers a burst with HTTP 429, and a typed trigger or a hotkey is as much a
---    burst as typing is.
--- 3. The last request time is kept per backend kind, because the agent, tone and
---    screen requests share the same map.
--- 4. Live mode keeps its own debounce at a word end.
--- ==============================================================================

local M = {}

local Debounce = require("llm.request_plan.debounce")

-- The option set this driver runs; compared with the corpus by the contract test.
M.OPTIONS = {
	allow_never = false,
	pace_explicit = true,
	pace_variants = true,
	floor_scope = "per_backend",
	live_instant_word_end = false,
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
