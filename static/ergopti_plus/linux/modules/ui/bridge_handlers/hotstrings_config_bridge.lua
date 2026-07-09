--- modules/ui/bridge_handlers/hotstrings_config_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Hotstrings Config Window
--- Handles JS→Lua messages from _shared/ui/hotstrings_config_window/.
--- Bridge name: "hotstrings_config_bridge"
--- Persists add/delete operations via the shared toml_codec.writer.
--- ==============================================================================

local M = {}
M.bridge_name = "hotstrings_config_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.hotstrings_config"

-- Lazy-loaded writer for hotstring TOML persistence.
local _writer = nil
local function _get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod) == "table" and type(mod.write) == "function" then _writer = mod end
	return _writer
end

--- Builds the initial data payload for the config UI.
--- @param state table Daemon state.
--- @return table Data the JS UI expects.
local function _build_initial_payload(state)
	local groups = {}
	if state.config and type(state.config.get_groups) == "function" then
		local raw = state.config:get_groups()
		for _, g in ipairs(raw) do
			local enabled = false
			if type(state.config.is_group_enabled) == "function" then
				enabled = state.config:is_group_enabled(g)
			end
			groups[#groups + 1] = { name = g, enabled = enabled }
		end
	end

	local mapping_count = 0
	local error_count = 0
	if state.config then
		if type(state.config.mapping_count) == "function" then
			mapping_count = state.config:mapping_count()
		end
		if type(state.config.parse_error_count) == "function" then
			error_count = state.config:parse_error_count()
		end
	end

	return {
		groups = groups,
		mapping_count = mapping_count,
		parse_errors = error_count,
		config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Hotstrings config UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "toggle_group" and payload.group then
		if state.config and type(state.config.toggle_group) == "function" then
			state.config:toggle_group(payload.group)
		end
		return _build_initial_payload(state)
	end

	if action == "reload" then
		if state.config and type(state.config.reload) == "function" then
			state.config:reload()
		end
		return _build_initial_payload(state)
	end

	if action == "add_hotstring" and payload.trigger and payload.replacement then
		local group = payload.group or "default"
		Logger.info(LOG, "Add hotstring: %s → %s (group=%s)",
			payload.trigger, payload.replacement, group)

		-- Persist to the group's TOML file.
		local config_dir = state.config and type(state.config.get_config_dir) == "function"
			and state.config:get_config_dir() or nil
		if config_dir then
			local path = config_dir .. "/" .. group .. ".toml"
			local writer = _get_writer()
			if writer then
				-- Build minimal data structure for this section.
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
					Logger.success(LOG, "Hotstring persisted: %s → %s", payload.trigger, payload.replacement)
				else
					Logger.error(LOG, "Failed to persist hotstring: %s", tostring(err))
				end
			end
		end
		return { added = true }
	end

	if action == "delete_hotstring" and payload.trigger then
		local group = payload.group or "default"
		Logger.info(LOG, "Delete hotstring: %s (group=%s)", payload.trigger, group)

		-- Remove from the group's TOML file.
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
					Logger.success(LOG, "Hotstring deleted: %s", payload.trigger)
				else
					Logger.error(LOG, "Failed to delete hotstring: %s", tostring(err))
				end
			end
		end
		return { deleted = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
