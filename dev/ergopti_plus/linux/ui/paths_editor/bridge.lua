--- ui/paths_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Paths / Config Editor
--- Handles JS->Lua messages from _shared/ui/paths_editor/.
--- Bridge name: "hsPaths"
--- Persists path settings via batch_write to config.toml.
--- ==============================================================================

local M = {}
M.bridge_name = "hsPaths"

local Logger = require("logger.shim")
local LOG = "bridge.hsPaths"

-- Read canonical version from the single-source module (SSoT).
local Version = require("infra.version")

-- Path to the daemon config file.
local function _config_path()
	return require("infra.config_paths").config("config.toml")
end

--- Builds the initial paths data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local home = require("infra.config_paths").home()
	local ConfigPaths = require("infra.config_paths")
	local paths = {
		config_dir = ConfigPaths.get_config_dir() .. "/",
		data_dir   = home .. "/.local/share/ergopti/",
		cache_dir  = home .. "/.cache/ergopti/",
		log_dir    = home .. "/.local/share/ergopti/logs/",
	}

	return {
		paths = paths,
		platform = "linux",
		version = state._version or Version.VERSION,
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
		if payload.key == "config_dir" then
			local ConfigPaths = require("infra.config_paths")
			local saved = ConfigPaths.set_config_dir(tostring(payload.value))
			if saved then
				Logger.success(LOG, "Configuration directory persisted: %s", ConfigPaths.get_config_dir())
			else
				Logger.error(LOG, "Configuration directory was not persisted — nothing changed.")
			end
			return { saved = saved }
		end

		-- The remaining path rows are configuration metadata, not bootstrap
		-- authorities, and stay in the effective config.toml.
		local ok_writer, writer = pcall(require, "toml_codec.writer")
		if ok_writer and type(writer.batch_write) == "function" then
			local ok, err = writer.batch_write(_config_path(), {
				{ section = "paths", key = payload.key, value = payload.value },
			})
			if ok then
				Logger.success(LOG, "Path persisted: %s = %s", payload.key, tostring(payload.value))
				return { saved = true }
			else
				Logger.error(LOG, "Failed to persist path: %s", tostring(err))
			end
		end
		return { saved = false }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
