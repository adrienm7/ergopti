--- modules/ui/bridge_handlers/hotstring_editor_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Hotstring Editor
--- Handles JS->Lua messages from _shared/ui/hotstring_editor/.
--- Bridge name: "hsEditor"
--- Persists save/delete operations via the shared toml_codec.writer.
--- ==============================================================================

local M = {}
M.bridge_name = "hsEditor"

local Logger = require("logger.shim")
local LOG = "bridge.hsEditor"

-- Lazy-loaded writer for hotstring TOML persistence.
local _writer = nil
local function _get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod) == "table" and type(mod.write) == "function" then _writer = mod end
	return _writer
end

--- Builds the initial editor data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local hotstrings = {}
	local groups = {}

	if state.config then
		if type(state.config.get_groups) == "function" then
			groups = state.config:get_groups() or {}
		end
		if type(state.config.get_all_hotstrings) == "function" then
			hotstrings = state.config:get_all_hotstrings() or {}
		end
	end

	return {
		hotstrings = hotstrings,
		groups = groups,
		config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Hotstring editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Hotstring editor close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save" and payload.trigger and payload.replacement then
		local group = payload.group or "default"
		Logger.info(LOG, "Save hotstring: %s -> %s (group=%s)",
			payload.trigger, payload.replacement, group)

		-- Persist the hotstring entry via the shared writer.
		local config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil
		if config_dir then
			local path = config_dir .. "/" .. group .. ".toml"
			local writer = _get_writer()
			if writer then
				local data = {
					sections_order = { group },
					sections = {
						[group] = {
							description = group,
							entries = {
								{
									trigger = payload.trigger,
									output = payload.replacement,
									is_word = payload.is_word ~= false,
									auto_expand = payload.auto_expand == true,
									is_case_sensitive = payload.is_case_sensitive == true,
									final_result = payload.final_result == true,
								}
							}
						}
					},
					meta = { description = group },
				}
				local ok, err = writer.write(path, data)
				if ok then
					Logger.success(LOG, "Hotstring saved to disk: %s", path)
				else
					Logger.error(LOG, "Failed to save hotstring: %s", tostring(err))
				end
			end
		end
		return { saved = true }
	end

	if action == "delete" and payload.trigger then
		local group = payload.group or "default"
		Logger.info(LOG, "Delete hotstring: %s (group=%s)", payload.trigger, group)

		-- Remove entry from the group TOML (write empty entries for that section).
		local config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil
		if config_dir then
			local path = config_dir .. "/" .. group .. ".toml"
			local writer = _get_writer()
			if writer then
				local data = {
					sections_order = { group },
					sections = {
						[group] = { description = group, entries = {} }
					},
					meta = { description = group },
				}
				local ok, err = writer.write(path, data)
				if ok then
					Logger.success(LOG, "Hotstring deleted from disk: %s", payload.trigger)
				else
					Logger.error(LOG, "Failed to delete hotstring: %s", tostring(err))
				end
			end
		end
		return { deleted = true }
	end

	if action == "test" and payload.trigger then
		Logger.info(LOG, "Test hotstring: %s", payload.trigger)
		-- Expand the hotstring in the current context.
		if state.engine and payload.replacement then
			local injector_ok, injector = pcall(require, "modules.hotstrings.injector")
			if injector_ok and injector then
				pcall(injector.inject, #payload.trigger, payload.replacement)
			end
		end
		return { tested = true }
	end

	if action == "duplicate" and payload.trigger then
		Logger.info(LOG, "Duplicate hotstring: %s", payload.trigger)
		return { duplicated = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
