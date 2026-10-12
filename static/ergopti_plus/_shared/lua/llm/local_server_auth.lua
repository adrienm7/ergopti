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

--- Captures only a canonical loopback origin and exact base path.
--- The common OpenAI response shape does not identify a server implementation.
--- @param raw any
--- @return string|nil
local function loopback_endpoint(raw)
	if type(raw) ~= "string" or raw:find("[%c%s]") or raw:find("\\", 1, true) then return nil end
	local scheme, authority, path = raw:match("^([%a][%w+%.%-]*)://([^/?#]+)(.*)$")
	if not scheme or authority:find("@", 1, true) or path:find("[?#]") then return nil end
	scheme = scheme:lower()
	if scheme ~= "http" and scheme ~= "https" then return nil end
	local host, port
	if authority:sub(1, 1) == "[" then
		host, port = authority:match("^(%[::1%]):(%d+)$")
		if authority == "[::1]" then host = authority end
	else
		host, port = authority:match("^([^:]+):(%d+)$")
		if not host and not authority:find(":", 1, true) then host = authority end
	end
	if not host then return nil end
	host = host:lower()
	if host ~= "localhost" and host ~= "127.0.0.1" and host ~= "[::1]" then return nil end
	local number = port and tonumber(port) or (scheme == "https" and 443 or 80)
	if not number or number < 1 or number > 65535 then return nil end
	return scheme .. ":" .. tostring(number) .. (path:gsub("/+$", ""))
end

--- Checks optional credentials only in the actual configured endpoint context.
--- A keyless loopback request proves availability through HTTP; it does not grant
--- product identity or readiness, and a remote generic URL still requires a key.
--- @param provider any
--- @param token any
--- @param base_url any
--- @param servers table Validated local catalogue.
--- @return boolean
function M.entry_token_allowed(provider, token, base_url, servers)
	if M.token_allowed(provider, token, servers) then return true end
	return token == "" and (provider == "openai" or provider == "openai_compat")
		and loopback_endpoint(base_url) ~= nil
end

--- Matches a configured entry without transferring its credentials to another URL.
--- Exact catalogue providers remain authoritative; generic providers need explicit
--- canonical loopback affinity, never a model name, user label or shared wire shape.
--- @param provider any
--- @param base_url any
--- @param server_id any
--- @param servers table Validated catalogue.
--- @return boolean
function M.entry_matches(provider, base_url, server_id, servers)
	local server = type(servers) == "table" and servers[server_id] or nil
	if type(server) ~= "table" or type(provider) ~= "string" or type(base_url) ~= "string" then return false end
	if provider == server_id then return true end
	if provider ~= "openai" and provider ~= "openai_compat" then return false end
	local configured, canonical = loopback_endpoint(base_url), loopback_endpoint(server.base_url)
	return configured ~= nil and canonical ~= nil and configured == canonical
end

--- Projects configured generic loopback endpoints as views, never new providers.
--- Canonical endpoints already belong to their declared catalogue row. Unknown
--- metadata and credentials remain private to the driver's originating entry.
--- @param entries table Validated native entries in their original order.
--- @param servers table Validated local catalogue.
--- @param providers table Actual provider descriptors.
--- @return table order Configured view identifiers only.
--- @return table views Public endpoint descriptors without credentials.
function M.configured_views(entries, servers, providers)
	local order, views = {}, {}
	for _, entry in ipairs(entries) do
		local provider = type(entry) == "table" and providers[entry.provider] or nil
		if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= ""
			and type(entry.token) == "string" and type(provider) == "table"
			and type(provider.label) == "string" and provider.label ~= ""
			and (entry.provider == "openai" or entry.provider == "openai_compat")
			and loopback_endpoint(entry.base_url) ~= nil then
			local canonical = false
			for id in pairs(servers) do
				if M.entry_matches(entry.provider, entry.base_url, id, servers) then canonical = true; break end
			end
			local id = "configured:" .. entry.id
			if not canonical and not views[id] then
				order[#order + 1] = id
				views[id] = { id = id, entry_id = entry.id, provider = entry.provider,
					label = provider.label, base_url = entry.base_url }
			end
		end
	end
	return order, views
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
