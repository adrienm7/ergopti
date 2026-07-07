--- modules/ui/bridge_handlers/onboarding_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Onboarding Wizard (first-run setup)
--- Handles JS→Lua messages from _shared/ui/onboarding/.
--- Bridge name: "hsOnboarding"
--- ==============================================================================

local M = {}
M.bridge_name = "hsOnboarding"

local Logger = require("logger.shim")
local LOG = "bridge.onboarding"

-- Forward declarations.
local _handle_init, _handle_layout, _handle_language, _handle_llm_setup, _handle_complete

local function _handle_init(state)
	local layout = state.layout or "qwerty"
	local locale = "fr"
	return {
		current_layout = layout,
		current_locale = locale,
		llm_available = state.llm ~= nil,
	}
end

local function _handle_layout(data, _)
	Logger.info(LOG, "Onboarding layout selected: %s", tostring(data.layout))
	return { accepted = true }
end

local function _handle_language(data, _)
	Logger.info(LOG, "Onboarding language selected: %s", tostring(data.locale))
	return { accepted = true }
end

local function _handle_llm_setup(data, state)
	Logger.info(LOG, "Onboarding LLM setup: model=%s url=%s",
		tostring(data.model), tostring(data.url))
	if state.llm and data.model and type(state.llm.set_model) == "function" then
		pcall(state.llm.set_model, state.llm, data.model)
	end
	return { accepted = true }
end

local function _handle_complete(data, _)
	Logger.success(LOG, "Onboarding complete — daemon ready.")
	return { done = true }
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) ~= "table" then
		local ok, data = pcall(function()
			local json_mod = require("json")
			return json_mod.decode(tostring(payload))
		end)
		if not ok or type(data) ~= "table" then return nil end
		payload = data
	end

	local step = payload.step
	local data = payload.data or {}

	if step == "init" then
		return _handle_init(state)
	elseif step == "layout" then
		return _handle_layout(data, state)
	elseif step == "language" then
		return _handle_language(data, state)
	elseif step == "llm_setup" then
		return _handle_llm_setup(data, state)
	elseif step == "complete" then
		return _handle_complete(data, state)
	end

	Logger.debug(LOG, "Unknown step: %s", tostring(step))
	return nil
end

return M
