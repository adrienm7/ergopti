-- _shared/lua/llm/request_plan/token_budget.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Token Budget
--- DESCRIPTION:
--- Decides how many output tokens one backend call may produce. A call that
--- returns a single prediction keeps the base budget (llm/prompt_builder.lua
--- derives it from the word limit); a batch call returns several predictions in
--- one answer, so every extra variant adds its own base budget plus the room of
--- its separator and numbering.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the base budget and the plan's per_call in, a number out.
--- 2. One overhead constant for every driver and backend, so a batch of three
---    cannot be cut short on one OS and complete on another.
--- 3. The retry budget is the same rule: a retried call gets the same extra room
---    the drivers' retry policy grants, never a budget of its own.
---
--- Pinned by _shared/tests/corpus/llm/request_plan_token_budget_vectors.json.
--- ==============================================================================

local M = {}

--- Tokens one variant of a batch answer spends on its numbering and separator.
M.BATCH_VARIANT_OVERHEAD = 5




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

local function require_count(name, value, minimum)
	if type(value) ~= "number" or value ~= value or value < minimum or value % 1 ~= 0 then
		error(name .. " must be a whole number from " .. minimum, 3)
	end
end

--- Budget of one backend call.
--- @param base_tokens number Budget of a single prediction (at least 1).
--- @param per_call number Predictions the call returns (the plan's per_call).
--- @return number tokens The call's output token limit.
function M.for_call(base_tokens, per_call)
	require_count("base_tokens", base_tokens, 1)
	require_count("per_call", per_call, 1)
	if per_call == 1 then return base_tokens end
	return per_call * (base_tokens + M.BATCH_VARIANT_OVERHEAD)
end

--- Budget of a retried call: the failed call's budget plus the retry policy's room.
--- @param call_tokens number The failed call's budget.
--- @param extra_tokens number The retry policy's extra tokens (0 or more).
--- @return number tokens The retried call's output token limit.
function M.for_retry(call_tokens, extra_tokens)
	require_count("call_tokens", call_tokens, 1)
	require_count("extra_tokens", extra_tokens, 0)
	return call_tokens + extra_tokens
end

return M
