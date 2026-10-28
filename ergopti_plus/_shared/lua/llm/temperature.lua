--- _shared/lua/llm/temperature.lua

--- ==============================================================================
--- MODULE: Diversity Temperature — Shared Lua Implementation
--- DESCRIPTION:
--- The temperature of each variant when several predictions are asked one
--- after another. The macOS backends (modules/llm/api_common.lua) and the Linux
--- engine (modules/llm/inference.lua) both compute it here, from the
--- `diversity_temperature` section of _shared/modules/llm/inference.json.
---
--- FEATURES & RATIONALE:
--- 1. The step depends on the base: a low base gets a bigger step to
---    compensate, a high base a smaller one so the variants stay coherent.
---    An explicit step replaces that choice.
--- 2. The first variant keeps the user's setting; from the second on, a base
---    below the floor is raised to it, so the next variants have headroom.
--- 3. The result never exceeds the policy's maximum.
---
--- The AutoHotkey twin is LLM_ApiCommon_GetDiversityTemp in
--- windows/modules/llm/api_common.ahk. Pinned by
--- _shared/tests/corpus/llm/temperature_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- The bases at or below which the larger steps apply; the policy keys name them.
local LOW_BASE = 0.15
local MEDIUM_BASE = 0.35

-- Every number the algorithm reads from the policy section.
M.POLICY_KEYS = {
	"step_when_base_le_0_15",
	"step_when_base_le_0_35",
	"step_default",
	"effective_base_floor",
	"max_temperature",
}




-- =============================================
-- =============================================
-- ======= 2/ Public API =======================
-- =============================================
-- =============================================

--- Validates a `diversity_temperature` policy section, raising on a missing
--- or non-numeric key: an unreadable policy is a broken install, not a reason
--- to invent a temperature.
--- @param policy table The decoded `diversity_temperature` section.
--- @return table policy The same table, proven complete.
function M.validate(policy)
	if type(policy) ~= "table" then error("diversity_temperature policy must be a table", 2) end
	for _, key in ipairs(M.POLICY_KEYS) do
		if type(policy[key]) ~= "number" then
			error(string.format("diversity_temperature.%s is not a number", key), 2)
		end
	end
	return policy
end

--- The step between two consecutive variants for a base temperature.
--- @param policy table A `diversity_temperature` policy section.
--- @param base number The user's temperature.
--- @return number step
function M.step(policy, base)
	M.validate(policy)
	if base <= LOW_BASE then return policy.step_when_base_le_0_15 end
	if base <= MEDIUM_BASE then return policy.step_when_base_le_0_35 end
	return policy.step_default
end

--- The temperature of one variant of a sequential multi-prediction.
--- @param policy table A `diversity_temperature` policy section.
--- @param base number The user's temperature.
--- @param index number 1-based variant index.
--- @param step number|nil Explicit step; nil chooses it from the base.
--- @return number temperature
function M.variant(policy, base, index, step)
	M.validate(policy)
	assert(type(base) == "number", "the base temperature must be a number")
	assert(type(index) == "number" and index >= 1, "the variant index must be a number from 1")
	assert(step == nil or type(step) == "number", "an explicit step must be a number")
	local delta = step or M.step(policy, base)
	local effective = base
	if index > 1 and effective < policy.effective_base_floor then effective = policy.effective_base_floor end
	return math.min(policy.max_temperature, effective + (index - 1) * delta)
end

return M
