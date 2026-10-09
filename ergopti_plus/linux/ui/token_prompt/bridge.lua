--- ui/token_prompt/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Token / Prompt Settings
--- DESCRIPTION:
--- Handles JS→Lua messages from _shared/ui/token_prompt/.
--- Bridge name: "token_bridge"
---
--- TWO OF ITS FOUR BRANCHES HAVE NO SENDER (checked 2026-08-06).
--- The shared page is a GitHub-token form: it creates the bridge and sends a
--- token, and it has never sent `save_settings` or `test_prompt`. Those two
--- branches were written for an LLM settings window that does not exist, so
--- from a user's point of view this window does not save any setting — the
--- controls for temperature and context length live in the tray menu instead.
---
--- They are kept rather than deleted because the engine functions behind them
--- are real API used elsewhere, and because the branches become correct the day
--- a page sends those messages. What is NOT acceptable is the previous state:
--- three of the four setters did not exist at all, and every call was skipped
--- by a `type(…) == "function"` guard — so if a page HAD sent a save, one field
--- in four would have applied and the window would have reported success.
--- `tests/unit/modules/llm/test_token_prompt_setters.lua` pins the contract now.
--- ==============================================================================

local M = {}
M.bridge_name = "token_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.token"

--- Builds the initial token/prompt data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local settings = {
		max_tokens = 256,
		temperature = 0.7,
		stop_sequences = {},
		triggers = { "//", ";;", "--" },
		max_context = 2000,
		auto_inject = true,
	}

	if state.llm then
		if type(state.llm.get_max_tokens) == "function" then
			settings.max_tokens = state.llm.get_max_tokens()
		end
		if type(state.llm.get_temperature) == "function" then
			settings.temperature = state.llm.get_temperature()
		end
		if type(state.llm.get_stop_sequences) == "function" then
			settings.stop_sequences = state.llm.get_stop_sequences() or {}
		end
		if type(state.llm.get_triggers) == "function" then
			settings.triggers = state.llm.get_triggers() or settings.triggers
		end
		if type(state.llm.get_max_context) == "function" then
			settings.max_context = state.llm.get_max_context()
		end
		if type(state.llm.is_auto_inject) == "function" then
			settings.auto_inject = state.llm.is_auto_inject()
		end
	end

	return settings
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Token prompt UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Token prompt close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save_settings" and payload.settings then
		Logger.info(LOG, "Save token/prompt settings.")
		if state.llm then
			local s = payload.settings
			if s.max_tokens and type(state.llm.set_max_tokens) == "function" then
				pcall(state.llm.set_max_tokens, s.max_tokens)
			end
			if s.temperature and type(state.llm.set_temperature) == "function" then
				pcall(state.llm.set_temperature, s.temperature)
			end
			if s.triggers and type(state.llm.set_triggers) == "function" then
				pcall(state.llm.set_triggers, s.triggers)
			end
			if s.max_context and type(state.llm.set_max_context) == "function" then
				pcall(state.llm.set_max_context, s.max_context)
			end
		end
		return { saved = true }
	end

	if action == "test_prompt" and payload.prompt then
		Logger.info(LOG, "Test prompt (length=%d).", #payload.prompt)
		if state.llm and type(state.llm.predict) == "function" then
			pcall(state.llm.predict, payload.prompt)
		end
		return { requested = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
