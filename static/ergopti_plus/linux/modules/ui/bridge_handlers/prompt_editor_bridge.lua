--- modules/ui/bridge_handlers/prompt_editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: LLM Prompt Editor
--- Handles JS→Lua messages from _shared/ui/prompt_editor/.
--- Bridge name: "prompt_bridge"
--- Persists model selection via batch_write to config.toml.
--- ==============================================================================

local M = {}
M.bridge_name = "prompt_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.prompt_editor"

-- Lazy-loaded writer for config.toml persistence.
local _writer = nil
local function _get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod.batch_write) == "function" then _writer = mod end
	return _writer
end

-- Path to the daemon config file.
local function _config_path()
	local home = require("lib.config_paths").home()
	return home .. "/.config/ergopti/config.toml"
end

--- Builds the initial data payload for the prompt editor UI.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local enabled = false
	local current_model = ""
	local models = {}

	if state.llm then
		if type(state.llm.is_enabled) == "function" then
			local ok, result = pcall(state.llm.is_enabled, state.llm)
			if ok then enabled = result end
		end
		if type(state.llm.get_current_model) == "function" then
			local ok, result = pcall(state.llm.get_current_model, state.llm)
			if ok then current_model = result or "" end
		end
		if type(state.llm.get_models) == "function" then
			local ok, result = pcall(state.llm.get_models, state.llm)
			if ok and type(result) == "table" then models = result end
		end
	end

	return {
		enabled = enabled,
		current_model = current_model,
		available_models = models,
		triggers = (function()
			if not state.llm or type(state.llm.get_triggers) ~= "function" then return {} end
			local ok, result = pcall(state.llm.get_triggers, state.llm)
			return (ok and type(result) == "table" and result) or {}
		end)(),
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Prompt editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh_models" then
			if state.llm and type(state.llm.refresh_models) == "function" then
				pcall(state.llm.refresh_models, state.llm)
			end
			return _build_initial_payload(state)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save_prompt" then
		Logger.info(LOG, "Save prompt: %s", tostring(payload.title))
		local writer = _get_writer()
		if writer and payload.title then
			local ok, err = writer.batch_write(_config_path(), {
				{ section = "llm", key = "prompt", value = payload.title },
			})
			if ok then
				Logger.success(LOG, "Prompt persisted: %s", payload.title)
			else
				Logger.error(LOG, "Failed to persist prompt: %s", tostring(err))
			end
		end
		return { saved = true }
	end

	if action == "set_model" and payload.model then
		Logger.info(LOG, "Set model: %s", payload.model)
		if state.llm and type(state.llm.set_model) == "function" then
			pcall(state.llm.set_model, state.llm, payload.model)
		end
		local writer = _get_writer()
		if writer then
			local ok, err = writer.batch_write(_config_path(), {
				{ section = "llm", key = "model", value = payload.model },
			})
			if ok then
				Logger.success(LOG, "Model persisted: %s", payload.model)
			else
				Logger.error(LOG, "Failed to persist model: %s", tostring(err))
			end
		end
		return { model = payload.model }
	end

	if action == "set_enabled" and payload.enabled ~= nil then
		if state.llm then
			if payload.enabled then
				if type(state.llm.enable) == "function" then
					pcall(state.llm.enable, state.llm)
				elseif type(state.llm.toggle) == "function" then
					if not (pcall(state.llm.is_enabled, state.llm) and true) then
						pcall(state.llm.toggle, state.llm)
					end
				end
			else
				if type(state.llm.disable) == "function" then
					pcall(state.llm.disable, state.llm)
				elseif type(state.llm.toggle) == "function" then
					if pcall(state.llm.is_enabled, state.llm) then
						pcall(state.llm.toggle, state.llm)
					end
				end
			end
		end
		return { enabled = payload.enabled }
	end

	if action == "toggle_enabled" then
		if state.llm and type(state.llm.toggle) == "function" then
			pcall(state.llm.toggle, state.llm)
		end
		local enabled = false
		if state.llm and type(state.llm.is_enabled) == "function" then
			pcall(function() enabled = state.llm:is_enabled() end)
		end
		return { enabled = enabled }
	end

	if action == "test_prediction" and payload.context then
		Logger.info(LOG, "Test prediction with context: %d chars", #payload.context)
		if state.llm and type(state.llm.predict) == "function" then
			pcall(state.llm.predict, state.llm, payload.context)
		end
		return { requested = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
