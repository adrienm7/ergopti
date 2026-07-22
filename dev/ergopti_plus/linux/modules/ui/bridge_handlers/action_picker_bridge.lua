--- modules/ui/bridge_handlers/action_picker_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Action Picker (Spotlight-style launcher)
--- Handles JS→Lua messages from _shared/ui/action_picker/.
--- Bridge name: "action_picker_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "action_picker_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.action_picker"

-- Forward declarations (defined before on_message for scoping).
local _handle_json, _handle_table

--- Handles a JSON string payload (shared — no duplicated JSON parsing).
local function _handle_json(payload_str, state)
	local ok, data = pcall(function()
		local json_mod = require("json")
		return json_mod.decode(payload_str)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return _handle_table(data, state)
end

--- Handles a structured table payload.
local function _handle_table(data, state)
	local action = data.action

	if action == "execute" and data.command then
		Logger.info(LOG, "Action picker execute: %s", data.command)
		return nil
	end

	if action == "search" and data.query then
		Logger.info(LOG, "Action picker search: %s", data.query)
		local results = {}
		if state.engine then
			results[#results + 1] = { type = "hotstrings", label = "Recharger les hotstrings" }
		end
		if state.keylogger then
			results[#results + 1] = { type = "metrics", label = "Afficher les stats" }
		end
		if state.config then
			results[#results + 1] = { type = "config", label = "Config hotstrings" }
		end
		return { results = results }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS (if any).
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Action picker UI ready.")
			return nil
		end
		if payload == "close" then
			Logger.info(LOG, "Action picker close requested.")
			return nil
		end
		return _handle_json(payload, state)
	end

	if type(payload) == "table" then
		return _handle_table(payload, state)
	end

	Logger.warn(LOG, "Unknown payload type: %s", type(payload))
	return nil
end

return M
