--- modules/ui/bridge_handlers/paths_editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Paths / Config Editor
--- Handles JS->Lua messages from _shared/ui/paths_editor/.
--- Bridge name: "hsPaths"
--- ==============================================================================

local M = {}
M.bridge_name = "hsPaths"

local Logger = require("logger.shim")
local LOG = "bridge.hsPaths"

--- Builds the initial paths data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local home = os.getenv("HOME") or "/home/user"
	local paths = {
		config_dir = home .. "/.config/ergopti/",
		data_dir   = home .. "/.local/share/ergopti/",
		cache_dir  = home .. "/.cache/ergopti/",
		log_dir    = home .. "/.local/share/ergopti/logs/",
	}

	-- Override with actual config dir if available.
	if state.config and type(state.config.get_config_dir) == "function" then
		paths.config_dir = state.config:get_config_dir() or paths.config_dir
	end

	return {
		paths = paths,
		platform = "linux",
		version = state._version or "3.0.0",
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Paths editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Paths editor close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "open" and payload.path then
		local path = tostring(payload.path)
		Logger.info(LOG, "Open path: %s", path)
		os.execute(string.format("xdg-open '%s' 2>/dev/null &",
			path:gsub("'", "'\\''")))
		return { opened = true }
	end

	if action == "save" and payload.key and payload.value then
		Logger.info(LOG, "Save path setting: %s = %s", payload.key, tostring(payload.value))
		return { saved = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
