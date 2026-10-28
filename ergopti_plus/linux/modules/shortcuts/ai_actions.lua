--- modules/shortcuts/ai_actions.lua
--- Decides whether a key binding to an AI action is armed.

--- ==============================================================================
--- MODULE: AI Action Gate (Linux)
--- DESCRIPTION:
--- With the AI switched off nothing of it runs, as on macOS and Windows: a key
--- bound to an AI action (`llm_*` in the shared catalogue) is not armed, so the
--- key reaches the application instead of being claimed and refused. Switching
--- the AI back on arms the keys again because the answer is read at each press.
---
--- FEATURES & RATIONALE:
--- 1. One predicate for every key-claiming layer (modifier chords, physical
---    slots, number-row tap keys, tap-hold taps) and for the touchpad gestures, so the layers
---    cannot disagree about which actions the AI switch covers.
--- 2. The switch is read from the prediction engine, which owns it at runtime.
---    An engine that never loaded cannot run any AI action, so its bindings are
---    not armed either.
--- ==============================================================================

local M = {}

-- Prefix shared by every AI action id in the shared catalogue.
local AI_ACTION_PREFIX = "llm_"

local ENGINE_MODULE = "modules.llm.prediction_engine"

--- Whether an action id is an AI action (prediction, prompts, screen reading,
--- tone, translation, agent, live mode).
--- @param action_name any
--- @return boolean
function M.is_ai_action(action_name)
	return type(action_name) == "string" and action_name:sub(1, #AI_ACTION_PREFIX) == AI_ACTION_PREFIX
end

--- Whether the AI is switched off right now, so that every AI action is
--- unarmed. An engine that never loaded counts as off.
--- @return boolean
function M.off()
	local engine = rawget(package.loaded, ENGINE_MODULE)
	if type(engine) ~= "table" or type(engine.is_enabled) ~= "function" then return true end
	return engine.is_enabled() ~= true
end

--- Whether a binding to this action must be left unarmed right now: an AI
--- action while the AI is switched off.
--- @param action_name any
--- @return boolean
function M.blocked(action_name)
	return M.is_ai_action(action_name) and M.off()
end

return M
