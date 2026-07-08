--- modules/ui/bridge_handlers/personal_info_editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Personal Info Editor
--- Handles JS->Lua messages from _shared/ui/personal_info_editor/.
--- Bridge name: "hsPersonalInfo"
--- ==============================================================================

local M = {}
M.bridge_name = "hsPersonalInfo"

local Logger = require("logger.shim")
local LOG = "bridge.hsPersonalInfo"

--- Builds the initial personal info payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local info = {
		first_name = "",
		last_name = "",
		email = "",
		phone = "",
		address = "",
		city = "",
		postal_code = "",
		country = "",
	}

	-- Try to load from the dynamic hotstrings manager which reads personal_info.toml.
	local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
	if ok_dh and dh and type(dh.get_personal_info) == "function" then
		local loaded = dh.get_personal_info()
		if type(loaded) == "table" then
			for k, v in pairs(loaded) do
				info[k] = v
			end
		end
	end

	return {
		info = info,
		trigger_char = "\\",  -- default magic key
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Personal info editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Personal info editor close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save" and payload.field and payload.value ~= nil then
		Logger.info(LOG, "Save personal info: %s = %s", payload.field, tostring(payload.value))

		-- Persist via the dynamic hotstrings manager.
		local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
		if ok_dh and dh and type(dh.set_personal_info_field) == "function" then
			pcall(dh.set_personal_info_field, payload.field, payload.value)
		end

		return { saved = true, field = payload.field }
	end

	if action == "save_all" and payload.info then
		Logger.info(LOG, "Save all personal info fields.")
		local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
		if ok_dh and dh and type(dh.set_personal_info) == "function" then
			pcall(dh.set_personal_info, payload.info)
		end
		return { saved = true }
	end

	if action == "reset" then
		Logger.info(LOG, "Reset personal info to defaults.")
		return _build_initial_payload(state)
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
