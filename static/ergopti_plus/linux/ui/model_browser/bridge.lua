--- ui/model_browser/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: LLM Model Browser
--- Handles JS->Lua messages from _shared/ui/model_browser/.
--- Bridge name: "model_browser_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "model_browser_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.model_browser"

-- Read canonical Ollama defaults from the shared bridge (single source of truth).
local HttpBridge = require("infra.llm_bridge")

--- Builds the initial model browser data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local models = {}
	local current_model = ""
	local provider = "ollama"
	local provider_url = "http://" .. (HttpBridge.OLLAMA_DEFAULT_HOST or "127.0.0.1") .. ":" .. (HttpBridge.OLLAMA_DEFAULT_PORT or 11434)

	if state.llm then
		if type(state.llm.get_models) == "function" then
			models = state.llm.get_models() or {}
		end
		if type(state.llm.get_current_model) == "function" then
			current_model = state.llm.get_current_model() or ""
		end
		if type(state.llm.get_provider_url) == "function" then
			provider_url = state.llm.get_provider_url() or provider_url
		end
	end

	return {
		models = models,
		current_model = current_model,
		provider = provider,
		provider_url = provider_url,
		enabled = state.llm and (function()
			if type(state.llm.is_enabled) == "function" then
				return state.llm.is_enabled()
			end
			return false
		end)() or false,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Model browser UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			if state.llm and type(state.llm.refresh_models) == "function" then
				pcall(state.llm.refresh_models)
			end
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Model browser close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "select" and payload.model then
		Logger.info(LOG, "Select model: %s", payload.model)
		if state.llm and type(state.llm.set_model) == "function" then
			pcall(state.llm.set_model, payload.model)
		end
		return { model = payload.model }
	end

	if action == "download" and payload.model then
		Logger.info(LOG, "Download model: %s", payload.model)
		if state.llm and type(state.llm.download_model) == "function" then
			pcall(state.llm.download_model, payload.model)
		end
		return { downloading = true, model = payload.model }
	end

	if action == "delete" and payload.model then
		Logger.info(LOG, "Delete model: %s (not implemented — manage models via Ollama CLI).", payload.model)
		return { deleted = false, error = "not implemented", model = payload.model }
	end

	if action == "set_provider_url" and payload.url then
		Logger.info(LOG, "Set provider URL: %s", payload.url)
		if state.llm and type(state.llm.set_provider_url) == "function" then
			pcall(state.llm.set_provider_url, payload.url)
		end
		return { url = payload.url }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
