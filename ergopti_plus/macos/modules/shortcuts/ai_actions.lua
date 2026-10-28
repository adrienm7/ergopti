--- modules/shortcuts/ai_actions.lua

--- ==============================================================================
--- MODULE: AI Action Gate (macOS)
--- DESCRIPTION:
--- With the AI switched off nothing of it runs: a key bound to an AI action
--- (`llm_*` in the shared catalogue) is not armed, so the key reaches the
--- application instead of being claimed and refused. Switching the AI back on
--- arms the keys again with no reload.
---
--- FEATURES & RATIONALE:
--- 1. One predicate for every key-claiming layer (configurable shortcut
---    hotkeys, physical shortcut slots, the number-row tap keys) and for the
---    touchpad gestures, so the layers cannot disagree about which actions the
---    AI switch covers. The same rule holds on Windows and Linux.
--- 2. The switch is read from the prediction engine, which owns it at runtime.
---    A layer that binds a native hotkey cannot ask at each press, so it
---    subscribes here and is told when the engine commits a switch.
--- 3. A Karabiner tap-hold cannot be bound to an `llm_*` action (its tap and
---    hold are Karabiner key events, never catalogue actions), so the tap-hold
---    layer has nothing to disarm on this platform.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local TableUtil = require("table_util")

local LOG = "shortcuts.ai_actions"

-- Prefix shared by every AI action id in the shared catalogue.
local AI_ACTION_PREFIX = "llm_"

local ENGINE_MODULE = "modules.llm.prediction_engine"

-- name -> function(): the layers told when the AI switch is committed.
local _listeners = {}

--- Whether an action id is an AI action (prediction, prompts, screen reading,
--- tone, translation, agent, live mode).
--- @param action_name any
--- @return boolean
function M.is_ai_action(action_name)
	return type(action_name) == "string" and action_name:sub(1, #AI_ACTION_PREFIX) == AI_ACTION_PREFIX
end

--- Whether the AI is switched off right now. An engine that never loaded
--- counts as off: it cannot run any AI action.
--- @return boolean
function M.off()
	local engine = rawget(package.loaded, ENGINE_MODULE)
	if type(engine) ~= "table" or type(engine.get_llm_enabled) ~= "function" then return true end
	return engine.get_llm_enabled() ~= true
end

--- Whether a binding to this action must be left unarmed right now: an AI
--- action while the AI is switched off.
--- @param action_name any
--- @return boolean
function M.blocked(action_name)
	return M.is_ai_action(action_name) and M.off()
end

--- Registers (or replaces) a layer's callback for the AI switch.
--- @param name string The layer, once per layer.
--- @param listener function Called with no argument after each committed switch.
function M.subscribe(name, listener)
	assert(type(name) == "string" and name ~= "", "ai_actions.subscribe: a layer name is required")
	assert(type(listener) == "function", "ai_actions.subscribe: a function is required")
	_listeners[name] = listener
end

--- Forgets a layer's callback.
--- @param name string
function M.unsubscribe(name)
	_listeners[name] = nil
end

--- Tells every layer that the AI switch was committed. A failing layer is
--- logged and the others still run.
function M.notify()
	for _, name in ipairs(TableUtil.sorted_keys(_listeners)) do
		local listener = _listeners[name]
		if listener then
			local ok, err = xpcall(listener, debug.traceback)
			if not ok then
				Logger.error(LOG, "The '%s' layer failed to follow the AI switch: %s.", name, tostring(err))
			end
		end
	end
end

return M
