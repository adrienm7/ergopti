--- ui/metrics_apps/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Metrics Apps Dashboard (per-app statistics)
--- Handles JS->Lua messages from _shared/ui/metrics_apps/.
--- Bridge name: "metrics_apps_bridge"
---
--- NOTE: This file replaces the formerly-named metrics_typing_bridge.lua
--- so that the module name matches the _shared/ui/ app directory convention
--- used by webview_manager._load_handler().
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_apps_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.metrics_apps"

--- Builds the shared metrics payload expected by the browser dashboard.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, include_prefetch)
	local keylogger = state.keylogger
	if keylogger and type(keylogger.get_dashboard_payload) == "function" then
		return keylogger.get_dashboard_payload({ include_prefetch = include_prefetch ~= false })
	end
	return {
		metrics_manifest = {},
		app_icons        = {},
		_prefetch_data   = { historical = {}, today = {} },
		driver_meta      = { os = "linux", heatmap_id = "kc" },
	}
end

--- Exposes the payload builder to the typing dashboard bridge.
--- @param state table Daemon state.
--- @return table Shared metrics payload.
function M.build_payload(state)
	return _build_initial_payload(state, true)
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Metrics apps UI ready.")
			return _build_initial_payload(state, true)
		end
		if payload == "refresh" then
			return _build_initial_payload(state, false)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action
	if action == "ready" or action == "refresh" then
		return _build_initial_payload(state, action == "ready")
	end

	if action == "reset" then
		if state.keylogger and type(state.keylogger.reset_session) == "function" then
			pcall(state.keylogger.reset_session)
		end
		return _build_initial_payload(state, true)
	end

	if action == "export" then
		if state.keylogger and type(state.keylogger.export_json) == "function" then
			local ok, json = pcall(state.keylogger.export_json)
			return { exported = ok, json = ok and json or nil }
		end
		return { exported = false }
	end

	if action == "pause" then
		if state.keylogger and type(state.keylogger.suppress) == "function" then
			state.keylogger.suppress()
		end
		return { suppressed = true }
	end

	if action == "resume" then
		if state.keylogger and type(state.keylogger.unsuppress) == "function" then
			state.keylogger.unsuppress()
		end
		return { suppressed = false }
	end

	if action == "app_detail" and payload.app_id then
		-- Return deeper stats for a specific app.
		if state.keylogger and type(state.keylogger.get_app_detail) == "function" then
			local detail = state.keylogger.get_app_detail(payload.app_id)
			return detail
		end
		return nil
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
