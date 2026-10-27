--- _shared/lua/llm/request_plan/agent.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Agent Admission
--- DESCRIPTION:
--- The decisions of the AI agent's flows that do not touch a native owner: which
--- refusal a manual agent action meets first, what blocks the automatic mode's
--- triage, and whether a typed sentence is worth triaging. The macOS agent runner
--- and the Linux prediction engine feed it facts (booleans and a mode) and carry
--- out the answer: the notice to show, the reason to log, the request to skip.
---
--- FEATURES & RATIONALE:
--- 1. One ladder per question, the same on both drivers: the order of the
---    refusals decides which notice the user sees, so it is data under test
---    (_shared/tests/corpus/llm/request_plan_agent_vectors.json), not two copies.
--- 2. A fact the driver cannot know yet is left out (nil) and its step is not
---    asked: Linux resolves System 2 after the switches, macOS in the same call.
--- 3. Pure: no clock, no settings read, no notice shown. The driver maps a step
---    to its notice key and its log wording.
--- ==============================================================================

local M = {}

--- The agent's modes (agent.lua MODES).
M.MODE_OFF, M.MODE_ACTION, M.MODE_AUTO = "off", "action", "auto"

--- Steps of the manual admission, in the order they are asked.
M.ADMIT_STEPS = { "paused", "ai_off", "mode_off", "no_system2", "focus_blocked" }

--- Notice kind of each refusing step; a blocked focus refuses silently.
M.ADMIT_NOTICE = { paused = "paused", ai_off = "disabled", mode_off = "agent_off", no_system2 = "no_system2" }

--- Blockers of the automatic mode, in the order they are asked.
M.AUTO_BLOCKERS = { "mode", "paused", "ai_off", "live", "ai_busy", "vision", "hotstring_preview", "focus_blocked" }

--- Why a sentence is not triaged.
M.SKIP_TOO_SHORT, M.SKIP_ALREADY_TRIAGED = "too_short", "already_triaged"

--- The refusal a manual agent action meets first.
--- @param facts table { paused, ai_enabled, mode, system2_usable?, focus_blocked? } booleans and the mode;
---   system2_usable and focus_blocked are nil while the driver has not asked them.
--- @return table decision { allowed = true } or { allowed = false, step, notice? }
function M.admit(facts)
	if type(facts) ~= "table" then error("admit needs a facts table", 2) end
	for _, name in ipairs({ "paused", "ai_enabled" }) do
		if type(facts[name]) ~= "boolean" then error("admit: " .. name .. " must be a boolean", 2) end
	end
	if facts.mode ~= M.MODE_OFF and facts.mode ~= M.MODE_ACTION and facts.mode ~= M.MODE_AUTO then
		error("admit: mode must be off, action or auto", 2)
	end
	local function refuse(step) return { allowed = false, step = step, notice = M.ADMIT_NOTICE[step] } end
	if facts.paused then return refuse("paused") end
	if not facts.ai_enabled then return refuse("ai_off") end
	if facts.mode == M.MODE_OFF then return refuse("mode_off") end
	if facts.system2_usable == false then return refuse("no_system2") end
	if facts.focus_blocked == true then return refuse("focus_blocked") end
	return { allowed = true }
end

--- What stops the automatic mode from looking at the typing now.
--- @param facts table { mode, paused, ai_enabled, live, ai_busy, vision, hotstring_preview, focus_blocked }
---   ai_busy is an explicit AI action in flight or shown, an automatic next-word prediction excepted.
--- @return string|nil blocker One of AUTO_BLOCKERS, or nil when the triage may run.
function M.auto_blocker(facts)
	if type(facts) ~= "table" then error("auto_blocker needs a facts table", 2) end
	for _, name in ipairs({ "paused", "ai_enabled", "live", "ai_busy", "vision", "hotstring_preview", "focus_blocked" }) do
		if type(facts[name]) ~= "boolean" then error("auto_blocker: " .. name .. " must be a boolean", 2) end
	end
	if facts.mode ~= M.MODE_AUTO then return "mode" end
	if facts.paused then return "paused" end
	if not facts.ai_enabled then return "ai_off" end
	if facts.live then return "live" end
	if facts.ai_busy then return "ai_busy" end
	if facts.vision then return "vision" end
	if facts.hotstring_preview then return "hotstring_preview" end
	if facts.focus_blocked then return "focus_blocked" end
	return nil
end

--- Whether a typed sentence is worth triaging.
--- @param facts table { chars, min_chars, already_triaged }
--- @return string|nil skip SKIP_TOO_SHORT, SKIP_ALREADY_TRIAGED or nil.
function M.triage_skip(facts)
	if type(facts) ~= "table" or type(facts.chars) ~= "number" or type(facts.min_chars) ~= "number"
		or type(facts.already_triaged) ~= "boolean" then
		error("triage_skip needs chars, min_chars and already_triaged", 2)
	end
	if facts.chars < facts.min_chars then return M.SKIP_TOO_SHORT end
	if facts.already_triaged then return M.SKIP_ALREADY_TRIAGED end
	return nil
end

return M
