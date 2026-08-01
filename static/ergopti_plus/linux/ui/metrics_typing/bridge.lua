--- ui/metrics_typing/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Typing Metrics Dashboard
--- DESCRIPTION:
--- Supplies the same manifest and n-gram prefetch envelope consumed by the
--- shared typing dashboard on macOS and Windows. Linux previously registered no
--- handler for this UI, so its WebKit page fell through to a missing file fetch
--- and could never receive live keylogger data.
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_typing_bridge"

local AppsBridge = require("ui.metrics_apps.bridge")
local Logger = require("logger.shim")
local LOG = "bridge.metrics_typing"

--- Handles a ready or refresh request from the shared typing dashboard.
--- @param payload any Request payload from the WebKit bridge.
--- @param state table Daemon state.
--- @return table|nil Shared metrics prefetch payload.
function M.on_message(payload, state)
	local action = type(payload) == "table" and payload.action or payload
	if action == "ready" or action == "refresh" then
		Logger.debug(LOG, "Typing metrics UI requested %s.", action)
		if state.keylogger and type(state.keylogger.get_dashboard_payload) == "function" then
			return state.keylogger.get_dashboard_payload({ include_prefetch = action == "ready" })
		end
		return AppsBridge.build_payload(state)
	end
	if action == "range" and type(payload) == "table" then
		if state.keylogger and type(state.keylogger.get_range_payload) == "function" then
			local range = state.keylogger.get_range_payload(payload.start_date, payload.end_date, payload.apps)
			return {
				metrics_manifest = state.keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest,
				app_icons = {},
				_prefetch_data = range,
				driver_meta = { os = "linux", heatmap_id = "kc" },
			}
		end
	end
	return nil
end

return M
