--- modules/ui/bridge_handlers/hotstrings_config_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Hotstrings Config Window
--- Handles JS→Lua messages from _shared/ui/hotstrings_config_window/.
--- Bridge name: "hotstrings_config_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "hotstrings_config_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.hotstrings_config"

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
		Logger.info(LOG, "Add hotstring: %s → %s (group=%s)",
			payload.trigger, payload.replacement, payload.group or "default")
		return { added = true }
	end

	if action == "delete_hotstring" and payload.trigger then
		Logger.info(LOG, "Delete hotstring: %s", payload.trigger)
		return { deleted = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
