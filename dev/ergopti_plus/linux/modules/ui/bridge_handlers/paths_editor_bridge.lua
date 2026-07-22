--- modules/ui/bridge_handlers/paths_editor_bridge.lua

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
local Version = require("lib.version")

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
	local home = os.getenv("HOME") or "/home/user"
	return home .. "/.config/ergopti/config.toml"
end

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
		local writer = _get_writer()
		if writer then
			local ok, err = writer.batch_write(_config_path(), {
				{ section = "paths", key = payload.key, value = payload.value },
			})
			if ok then
				Logger.success(LOG, "Path persisted: %s = %s", payload.key, tostring(payload.value))
			else
				Logger.error(LOG, "Failed to persist path: %s", tostring(err))
			end
		end
		return { saved = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
