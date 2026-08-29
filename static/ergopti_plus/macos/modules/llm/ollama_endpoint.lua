--- modules/llm/ollama_endpoint.lua

--- ==============================================================================
--- MODULE: Ollama Endpoint Owner
--- DESCRIPTION:
--- Resolves the one loopback Ollama endpoint shared by HTTP clients, readiness
--- probes and daemon launchers. A persisted user override wins; otherwise the
--- already-loaded shared LLM defaults remain authoritative.
--- ==============================================================================

local M = {}

local Logger  = require("infra.logger")
local Storage = require("adapters.storage")

local LOG = "llm.ollama_endpoint"
local HOST = "127.0.0.1"
local PORT_SETTING_KEY = "llm.ollama_port"
local PORT_MIN, PORT_MAX = 1024, 65535
local EMERGENCY_PORT = 11434

--- Reads a valid persisted user override.
--- @return integer|nil port
function M.read_port_override()
	local ok, value = pcall(Storage.get, PORT_SETTING_KEY)
	if not ok then return nil end
	value = tonumber(value)
	if type(value) ~= "number" or value % 1 ~= 0
		or value < PORT_MIN or value > PORT_MAX then
		return nil
	end
	return value
end

--- Reads the canonical shared default without creating an init require cycle.
--- @return integer port
function M.get_default_port()
	local Core = package.loaded["modules.llm.init"]
	local value = Core and Core.DEFAULT_STATE
		and tonumber(Core.DEFAULT_STATE.llm_ollama_port) or nil
	if type(value) == "number" and value % 1 == 0
		and value >= PORT_MIN and value <= PORT_MAX then
		return value
	end
	Logger.error(LOG,
		"llm_ollama_port is unavailable from the loaded shared defaults — using the emergency port.")
	return EMERGENCY_PORT
end

--- Resolves the canonical live port.
--- @return integer port
function M.get_port()
	return M.read_port_override() or M.get_default_port()
end

--- Resolves the canonical live loopback base URL.
--- @return string url
function M.get_base_url()
	return "http://" .. HOST .. ":" .. tostring(M.get_port())
end

return M
