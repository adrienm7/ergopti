--- modules/llm/request_plan_policy.lua

--- ==============================================================================
--- MODULE: Prediction Request Plan Policy (macOS)
--- DESCRIPTION:
--- The choices macOS makes where the shared request plan
--- (_shared/lua/llm/request_plan) leaves a driver option, and the factory that
--- builds the engine's plan from the backend floor. The corpus
--- _shared/tests/corpus/llm/request_plan_debounce_vectors.json declares the same
--- table under driver_options.macos and the contract test compares the two.
---
--- FEATURES & RATIONALE:
--- 1. "Never" is a macOS menu setting (a negative debounce turns the automatic
---    trigger off), so the plan accepts a negative debounce here only.
--- 2. An explicit request (the manual hotkey, a prompt action, the chain after an
---    accepted prediction) is never throttled by the floor, as the floor's own
---    commit (05b4b79338) documents; the variants of a sequential request are not
---    paced either, the backend modules own their cadence.
--- 3. The last request time is one value, whatever the backend, as on Windows.
--- ==============================================================================

local M = {}

local Debounce = require("llm.request_plan.debounce")

-- The option set this driver runs; compared with the corpus by the contract test.
M.OPTIONS = {
	allow_never = true,
	pace_explicit = false,
	pace_variants = false,
	floor_scope = "global",
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
