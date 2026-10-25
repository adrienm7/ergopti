--- modules/llm/local_server_catalogue.lua

--- ==============================================================================
--- MODULE: Local API Catalogue Port
--- DESCRIPTION:
--- Reads shared optional-auth descriptors without initializing an HTTP client or
--- credential store. Missing capability stays unavailable rather than guessed.
--- ==============================================================================

local M = {}
local Json = require("json")
local Paths = require("infra.paths")
local Logger = require("logger.shim")
local Policy = require("llm.local_server_auth")
local Reader = require("infra.regular_file_reader")

--- Reads only admitted regular sources whose read and close both acknowledge.
--- A partial receipt cannot grant optional-auth capability to downstream callers.
--- @param path string|nil Resolved packaged source.
--- @return string|nil bytes
local function read_source(path)
	local acquired, file = pcall(Reader.open_source, path)
	if not acquired or not file then return nil end
	local read, bytes = pcall(file.read, file, "*a")
	local closed, acknowledged = pcall(file.close, file)
	if not read or type(bytes) ~= "string" or not closed or acknowledged ~= true then return nil end
	return bytes
end

--- Reads the current shared catalogue and refuses collisions with cloud ids.
--- @param occupied table Registered cloud provider descriptors.
--- @return table order
--- @return table servers
--- @return boolean published Complete admitted nonempty local inventory.
function M.load(occupied)
	local path = Paths.shared("modules/llm/local_servers.json")
	local raw = read_source(path)
	local root = type(raw) == "string" and Json.decode(raw) or nil
	if type(root) ~= "table" then
		Logger.error("llm.local_server_catalogue", "The local API catalogue is unavailable; optional authentication is refused.")
		return {}, {}, false
	end
	-- Storage and transport consult the same authoritative cloud identities.
	-- A local descriptor cannot shadow a registered cloud provider.
	local cloud_path = Paths.shared("modules/llm/api_providers.json")
	local cloud_raw = read_source(cloud_path)
	local cloud = type(cloud_raw) == "string" and Json.decode(cloud_raw) or nil
	if type(cloud) ~= "table" or type(cloud.providers) ~= "table" then return {}, {}, false end
	local claimed = {}
	for id in pairs(cloud.providers) do claimed[id] = true end
	for id in pairs(occupied or {}) do claimed[id] = true end
	local order, servers = Policy.catalogue(root, claimed)
	local published = #order > 0
	return order, servers, published
end

return M
