--- modules/llm/ollama_endpoint.lua

--- ==============================================================================
--- MODULE: Ollama Endpoint Owner
--- DESCRIPTION:
--- Resolves the one loopback Ollama endpoint shared by HTTP clients, readiness
--- probes and daemon launchers: the port of the Ollama Ergopti installs and pins
--- itself (llm_ollama_owned_port), never a user's own Ollama on 11434. A
--- persisted user override wins; otherwise the already-loaded shared LLM
--- defaults remain authoritative. Also names the
--- requirement failure "nothing answers at this endpoint", which the models
--- manager reports and the AI menu turns into the error that offers its fixes.
--- ==============================================================================

local M = {}

local Logger  = require("infra.logger")
local Storage = require("adapters.storage")

local LOG = "llm.ollama_endpoint"
local HOST = "127.0.0.1"
local PORT_SETTING_KEY = "llm.ollama_owned_port"
-- Before Ergopti owned its daemon it shared the stock Ollama port, under this key.
local LEGACY_PORT_SETTING_KEY = "llm.ollama_port"
local PORT_MIN, PORT_MAX = 1024, 65535
-- Used only when the shared defaults are not loaded yet, as before ownership.
-- It is the owned port, so even this path never reaches a user's own Ollama.
local EMERGENCY_PORT = 11435
local _legacy_port_migrated = false

-- Cancel reason of a requirement check whose Ollama never answered at the
-- endpoint: not installed, not started, or started and still silent
M.UNREACHABLE = "ollama_unreachable"

--- Returns the shared default named by `key` from the loaded LLM defaults.
--- @param key string Shared defaults key.
--- @return integer|nil port
local function shared_port(key)
	local Core = package.loaded["modules.llm"]
	local value = Core and Core.DEFAULT_STATE and tonumber(Core.DEFAULT_STATE[key]) or nil
	if type(value) == "number" and value % 1 == 0 and value >= PORT_MIN and value <= PORT_MAX then
		return value
	end
	return nil
end

--- The stock Ollama port, which a user's own Ollama keeps.
--- @return integer|nil port
local function user_ollama_port()
	return shared_port("llm_ollama_port")
end

--- Validates one port value.
--- @param value any Candidate.
--- @return integer|nil port
local function valid_port(value)
	value = tonumber(value)
	if type(value) ~= "number" or value % 1 ~= 0 or value < PORT_MIN or value > PORT_MAX then return nil end
	return value
end

--- Moves the pre-owned override once. An override naming the stock Ollama port
--- (11434) is dropped, since the user's own Ollama keeps that port, and the
--- owned default applies; any other value was chosen for Ergopti's daemon and
--- moves to the owned key. Logged once.
--- @return boolean settled True once no legacy value remains.
function M.migrate_legacy_port()
	if _legacy_port_migrated then return true end
	local read_ok, legacy = pcall(Storage.get, LEGACY_PORT_SETTING_KEY)
	if not read_ok then return false end
	if legacy == nil then _legacy_port_migrated = true; return true end
	local port = valid_port(legacy)
	if port ~= nil and port ~= user_ollama_port() then
		local wrote, written = pcall(Storage.set, PORT_SETTING_KEY, port)
		if not wrote or written == false then
			Logger.error(LOG, "Cannot move the Ollama port override to its owned key; it stays at %d.", port)
			return false
		end
	end
	local removed, deleted = pcall(Storage.delete, LEGACY_PORT_SETTING_KEY)
	if not removed or deleted == false then
		Logger.error(LOG, "Cannot remove the former shared Ollama port override.")
		return false
	end
	_legacy_port_migrated = true
	if port ~= nil and port ~= user_ollama_port() then
		Logger.info(LOG, "Moved the Ollama port override %d to Ergopti's own daemon setting.", port)
	else
		Logger.info(LOG, "Dropped the former Ollama port %s: Ergopti's own daemon now uses its own port %d.",
			tostring(legacy), M.get_default_port())
	end
	return true
end

--- Reads a valid persisted user override.
--- @return integer|nil port
function M.read_port_override()
	M.migrate_legacy_port()
	local ok, value = pcall(Storage.get, PORT_SETTING_KEY)
	if not ok then return nil end
	value = valid_port(value)
	-- Never the stock port: Ergopti's daemon must not meet a user's own Ollama.
	if value == nil or value == user_ollama_port() then return nil end
	return value
end

--- Reads the canonical shared default without creating an init require cycle.
--- @return integer port
function M.get_default_port()
	local value = shared_port("llm_ollama_owned_port")
	if value == nil then
		Logger.error(LOG,
			"llm_ollama_owned_port is unavailable from the loaded shared defaults — using the emergency port.")
		return EMERGENCY_PORT
	end
	-- A shared default equal to the stock port would meet a user's own Ollama.
	assert(value ~= user_ollama_port(), "llm_ollama_owned_port must differ from the stock Ollama port")
	return value
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
