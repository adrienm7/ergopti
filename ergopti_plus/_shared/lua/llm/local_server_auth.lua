--- _shared/lua/llm/local_server_auth.lua

--- ==============================================================================
--- MODULE: Local API Authentication
--- DESCRIPTION:
--- The shared catalogue grants optional authentication to known local providers.
--- Drivers own configured URL validation, credential storage and HTTP lifecycle.
--- ==============================================================================

local M = {}
local Json = require("json")





-- ===============================================
-- ===============================================
-- ======= 1/ Catalogue And Authentication =======
-- ===============================================
-- ===============================================

--- Projects only validated optional-auth providers without overriding cloud ids.
--- @param root any Decoded local_servers.json.
--- @param occupied table Registered cloud providers.
--- @return table order
--- @return table servers
function M.catalogue(root, occupied)
	local order, servers = {}, {}
	if type(root) ~= "table" or type(root.server_order) ~= "table"
		or type(root.servers) ~= "table" or type(occupied) ~= "table" then return order, servers end
	for _, id in ipairs(root.server_order) do
		local desc = type(id) == "string" and root.servers[id] or nil
		if type(desc) == "table" and id:match("^[a-z][a-z0-9_]*$")
			and occupied[id] == nil and servers[id] == nil and desc.auth == "optional"
			and type(desc.label) == "string" and desc.label ~= ""
			and type(desc.base_url) == "string" and desc.base_url:match("^https?://%S+$") then
			servers[id] = { id = id, label = desc.label, base_url = desc.base_url, auth = desc.auth }
			order[#order + 1] = id
		end
	end
	return order, servers
end

--- Checks authentication material, independently of configured endpoint ownership.
--- Callers first resolve a registered provider; no stored row can grant capability.
--- @param provider_id any Actual registered provider identity.
--- @param token any Cleartext or opaque stored token; an empty string is explicit.
--- @param servers table Validated local catalogue, not user entry metadata.
--- @return boolean
function M.token_allowed(provider_id, token, servers)
	if type(provider_id) ~= "string" or provider_id == "" or type(token) ~= "string" then return false end
	if token ~= "" then return true end
	local server = type(servers) == "table" and servers[provider_id] or nil
	return type(server) == "table" and server.auth == "optional"
end

--- Validates a complete local OpenAI models receipt, preserving server order.
--- @param result any Actual native HTTP result.
--- @return table|nil model_ids
--- @return string|nil reason
function M.models_receipt(result)
	if type(result) ~= "table" or result.ok ~= true or result.status ~= 200 then
		return nil, "http_failure"
	end
	if type(result.body) ~= "string" or result.body_truncated == true then return nil, "invalid_models" end
	local root = Json.decode_lossless(result.body)
	if type(root) ~= "table" or Json.is_array(root) or not Json.is_array(root.data) then
		return nil, "invalid_models"
	end
	local ids = {}
	for _, row in ipairs(root.data) do
		if type(row) ~= "table" or Json.is_array(row) or type(row.id) ~= "string" or row.id == "" then
			return nil, "invalid_models"
		end
		ids[#ids + 1] = row.id
	end
	return ids
end

return M
