--- modules/ui/bridge_handlers/metrics_typing_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Metrics Typing Dashboard
--- Handles JS→Lua messages from _shared/ui/metrics_typing/.
--- Bridge name: "metrics_apps_bridge"
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_apps_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.metrics_typing"

--- Builds the initial data payload for the metrics UI.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	if not state.keylogger then
		return { keystrokes = 0, wpm = 0, words = 0, duration_ms = 0, apps = {} }
	end

	local k = state.keylogger
	local stats = { keystrokes = 0, words = 0, duration_ms = 0 }
	local wpm = 0.0
	local apps = {}

	if type(k.get_session_stats) == "function" then
		stats = k.get_session_stats(k)
	end
	if type(k.get_wpm) == "function" then
		wpm = k.get_wpm(k)
	end
	if type(k.get_app_stats) == "function" then
		apps = k.get_app_stats(k)
	end

	return {
		keystrokes  = stats.keystrokes,
		words       = stats.words,
		wpm         = wpm,
		duration_ms = stats.duration_ms,
		apps        = apps,
		suppressed  = type(k.is_suppressed) == "function" and k:is_suppressed() or false,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Metrics typing UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "reset" then
		if state.keylogger and type(state.keylogger.reset_session) == "function" then
			pcall(state.keylogger.reset_session, state.keylogger)
		end
		return _build_initial_payload(state)
	end

	if action == "export" then
		if state.keylogger and type(state.keylogger.export_json) == "function" then
			local ok, json = pcall(state.keylogger.export_json, state.keylogger)
			return { exported = ok, json = ok and json or nil }
		end
		return { exported = false }
	end

	if action == "pause" then
		if state.keylogger and type(state.keylogger.suppress) == "function" then
			state.keylogger:suppress()
		end
		return { suppressed = true }
	end

	if action == "resume" then
		if state.keylogger and type(state.keylogger.unsuppress) == "function" then
			state.keylogger:unsuppress()
		end
		return { suppressed = false }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
