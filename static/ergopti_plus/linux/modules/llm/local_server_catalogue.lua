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

--- Reads the current shared catalogue and refuses collisions with cloud ids.
--- @param occupied table Registered cloud provider descriptors.
--- @return table order
--- @return table servers
function M.load(occupied)
	local path = Paths.shared("modules/llm/local_servers.json")
	local file = path and io.open(path, "rb")
	local raw = file and file:read("*a") or nil
	if file then file:close() end
	local root = type(raw) == "string" and Json.decode(raw) or nil
	if type(root) ~= "table" then
		Logger.error("llm.local_server_catalogue", "The local API catalogue is unavailable; optional authentication is refused.")
		return {}, {}
	end
	-- Storage and transport consult the same authoritative cloud identities.
	-- A local descriptor cannot shadow a registered cloud provider.
	local cloud_path = Paths.shared("modules/llm/api_providers.json")
	local cloud_file = cloud_path and io.open(cloud_path, "rb")
	local cloud_raw = cloud_file and cloud_file:read("*a") or nil
	if cloud_file then cloud_file:close() end
	local cloud = type(cloud_raw) == "string" and Json.decode(cloud_raw) or nil
	if type(cloud) ~= "table" or type(cloud.providers) ~= "table" then return {}, {} end
	local claimed = {}
	for id in pairs(cloud.providers) do claimed[id] = true end
	for id in pairs(occupied or {}) do claimed[id] = true end
	return Policy.catalogue(root, claimed)
end

return M
