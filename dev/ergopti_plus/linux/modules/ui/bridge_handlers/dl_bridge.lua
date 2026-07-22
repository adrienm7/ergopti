--- modules/ui/bridge_handlers/dl_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Download Window
--- Handles JS->Lua messages from _shared/ui/download_window/.
--- Bridge name: "dl_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "dl_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.dl"

--- Builds the initial download state payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local downloads = {}

	-- Check if the updater has an active download.
	local ok_up, updater = pcall(require, "modules.updater.manager")
	if ok_up and updater then
		local dl_state = updater.get_state()
		if dl_state == "downloading" then
			downloads[#downloads + 1] = {
				url = "",
				filename = "ergopti_update.tar.gz",
				status = "downloading",
				progress = 0,
			}
		end
	end

	return {
		downloads = downloads,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Download window UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Download window close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "cancel" and payload.id then
		Logger.info(LOG, "Cancel download: %s", tostring(payload.id))
		return { cancelled = true }
	end

	if action == "retry" and payload.url then
		Logger.info(LOG, "Retry download: %s", tostring(payload.url))
		return { started = true }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
