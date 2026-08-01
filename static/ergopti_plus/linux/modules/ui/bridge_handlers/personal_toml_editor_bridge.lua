--- modules/ui/bridge_handlers/personal_toml_editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Personal Info TOML Editor
--- Handles JS->Lua messages from _shared/ui/personal_info_editor/ (TOML flavour).
--- Bridge name: "personal_toml_editor"
--- ==============================================================================

local M = {}
M.bridge_name = "personal_toml_editor"

local Logger = require("logger.shim")
local LOG = "bridge.personal_toml"

--- Builds the initial TOML payload showing raw personal_info.toml content.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local toml_content = ""
	local toml_path = ""

	-- Try to read the actual personal_info.toml file.
	local home = require("infra.config_paths").home()
	local candidates = {
		home .. "/.config/ergopti/hotstrings/personal_info.toml",
	}

	-- Also check from the shared defaults.
	local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
	if ok_dh and dh and type(dh.get_config_path) == "function" then
		local path = dh.get_config_path()
		if path then
			table.insert(candidates, 1, path)
		end
	end

	for _, path in ipairs(candidates) do
		local fh = io.open(path, "r")
		if fh then
			toml_content = fh:read("*a") or ""
			fh:close()
			toml_path = path
			break
		end
	end

	return {
		toml_content = toml_content,
		toml_path = toml_path,
		readonly = false,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Personal TOML editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Personal TOML editor close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save" and payload.content then
		Logger.info(LOG, "Save TOML content (%d bytes).", #payload.content)
		local data = _build_initial_payload(state)
		if data.toml_path ~= "" then
			local fh = io.open(data.toml_path, "w")
			if fh then
				fh:write(payload.content)
				fh:close()
				return { saved = true, path = data.toml_path }
			else
				return { saved = false, error = "Could not write to TOML file." }
			end
		end
		return { saved = false, error = "No TOML path configured." }
	end

	if action == "reload" then
		-- Reload the dynamic hotstrings engine so changes take effect.
		local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
		if ok_dh and dh and type(dh.reload) == "function" then
			pcall(dh.reload)
		end
		return _build_initial_payload(state)
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
