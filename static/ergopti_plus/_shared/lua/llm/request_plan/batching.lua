--- _shared/lua/llm/request_plan/batching.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Batching
--- DESCRIPTION:
--- Decides how many backend calls one prediction request takes: a batch profile
--- asks once for every variant, any other profile asks once per variant, one
--- after another. The rule is the one the shared prompt selector applies
--- (llm/profile_selector.lua: a batch prompt is a batch only above one
--- prediction), so the prompt asked for and the calls made cannot disagree.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the profile's flag and the requested count in, a plan out.
--- 2. The per-call token multiplier comes from the same plan, so the budget of a
---    batch grows with its variants and a sequential variant keeps its own.
---
--- Pinned by _shared/tests/corpus/llm/request_plan_batching_vectors.json.
--- ==============================================================================

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Plans the backend calls of one prediction request.
--- @param batch_profile boolean Whether the profile asks for a batch.
--- @param requested number Predictions the request asks for (at least 1).
--- @return table plan { mode = "batch"|"sequential", calls = number, per_call = number }
function M.plan(batch_profile, requested)
	if type(batch_profile) ~= "boolean" then error("batch_profile must be a boolean", 2) end
	if type(requested) ~= "number" or requested ~= requested or requested < 1 or requested % 1 ~= 0 then
		error("requested must be a whole number from 1", 2)
	end
	if batch_profile and requested > 1 then
		return { mode = "batch", calls = 1, per_call = requested }
	end
	return { mode = "sequential", calls = requested, per_call = 1 }
end

return M
