--- modules/ui/bridge_handlers/healthcheck_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Healthcheck Dashboard
--- Handles JS→Lua messages from _shared/ui/healthcheck/.
--- Bridge name: "healthcheck"
--- ==============================================================================

local M = {}
M.bridge_name = "healthcheck"

local Logger = require("logger.shim")
local LOG = "bridge.healthcheck"

-- Single source of the driver version (never a re-typed literal).
local Version = require("lib.version")

--- Builds the healthcheck data payload.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local modules = {}

	-- Engine
	modules.engine = { loaded = state.engine ~= nil, status = state.engine and "ok" or "missing" }

	-- Keylogger
	if state.keylogger then
		local stats = { keystrokes = 0 }
		if type(state.keylogger.get_session_stats) == "function" then
			stats = state.keylogger:get_session_stats()
		end
		modules.keylogger = {
			loaded = true,
			status = "ok",
			keystrokes = stats.keystrokes,
			suppressed = type(state.keylogger.is_suppressed) == "function"
				and state.keylogger:is_suppressed() or false,
		}
	else
		modules.keylogger = { loaded = false, status = "missing" }
	end

	-- Config
	if state.config then
		modules.config = {
			loaded = true,
			status = "ok",
			mapping_count = type(state.config.mapping_count) == "function"
				and state.config:mapping_count() or 0,
			parse_errors = type(state.config.parse_error_count) == "function"
				and state.config:parse_error_count() or 0,
		}
	else
		modules.config = { loaded = false, status = "missing" }
	end

	-- LLM
	if state.llm then
		local enabled = false
		if type(state.llm.is_enabled) == "function" then
			pcall(function() enabled = state.llm:is_enabled() end)
		end
		local model = ""
		if type(state.llm.get_current_model) == "function" then
			pcall(function() model = state.llm:get_current_model() or "" end)
		end
		modules.llm = {
			loaded = true,
			status = enabled and "ok" or "disabled",
			model = model,
		}
	else
		modules.llm = { loaded = false, status = "missing" }
	end

	-- Layout
	modules.layout = { loaded = true, layout = state.layout or "qwerty" }

	return {
		modules = modules,
		version = Version.VERSION,
		platform = "linux",
		locale = "fr",
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Healthcheck UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	Logger.debug(LOG, "Unknown action: %s", tostring(payload.action))
	return nil
end

return M
