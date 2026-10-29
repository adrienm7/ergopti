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

--- Copies one request field value made only of JSON scalars and objects.
--- @param value any Decoded JSON value.
--- @return any|nil copy nil when a part cannot travel as plain JSON.
local function copy_request_value(value)
	local kind = type(value)
	if kind == "boolean" or kind == "string" or (kind == "number" and value == value) then return value end
	if kind ~= "table" or Json.is_array(value) or next(value) == nil then return nil end
	local copy = {}
	for key, nested in pairs(value) do
		if type(key) ~= "string" or not key:match("^[A-Za-z_][A-Za-z0-9_]*$") then return nil end
		local kept = copy_request_value(nested)
		if kept == nil then return nil end
		copy[key] = kept
	end
	return copy
end

--- Projects the body fields every request to a local server carries.
--- Documentation keys start with _; a field that cannot travel as plain JSON
--- is dropped alone, so one bad field never disables the others.
--- @param root any Decoded local_servers.json.
--- @return table fields Field name -> value (possibly empty).
function M.request_fields(root)
	local fields = {}
	local raw = type(root) == "table" and root.request_fields or nil
	if type(raw) ~= "table" or Json.is_array(raw) then return fields end
	for name, value in pairs(raw) do
		if type(name) == "string" and name:match("^[A-Za-z][A-Za-z0-9_]*$") then
			fields[name] = copy_request_value(value)
		end
	end
	return fields
end

--- Merges the local request fields into an OpenAI-shape body.
--- A field the body already sets wins, so no catalogue entry can replace the
--- model, the messages or the token budget of a request.
--- @param body table Request body, modified in place.
--- @param fields table|nil Output of request_fields.
--- @return table body
function M.apply_request_fields(body, fields)
	if type(body) ~= "table" or type(fields) ~= "table" then return body end
	for name, value in pairs(fields) do
		if body[name] == nil then body[name] = value end
	end
	return body
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

--- Finds the key a running local server's own settings file holds for a
--- request the user gave no key: the scanned server of that catalogue
--- provider, else, for a generic provider, the scanned server listening at
--- the same canonical loopback endpoint. A key never leaves loopback.
--- @param provider any Provider id of the entry or probe.
--- @param base_url any Its configured address; "" for the scanned address.
--- @param scans table Server id -> { running, base_url, api_key }.
--- @param servers table Validated catalogue.
--- @return string key "" when no scanned server holds one.
function M.discovered_key(provider, base_url, scans, servers)
	if type(provider) ~= "string" or type(scans) ~= "table" or type(servers) ~= "table" then return "" end
	local typed = type(base_url) == "string" and base_url ~= ""
	local configured = typed and loopback_endpoint(base_url) or nil
	if typed and not configured then return "" end
	local function key_of(id)
		local scan = scans[id]
		if type(scan) ~= "table" or scan.running ~= true or type(scan.api_key) ~= "string" or scan.api_key == "" then return nil end
		local scanned = loopback_endpoint(scan.base_url)
		if not scanned or (configured and configured ~= scanned) then return nil end
		return scan.api_key
	end
	if servers[provider] ~= nil then return key_of(provider) or "" end
	if (provider ~= "openai" and provider ~= "openai_compat") or not configured then return "" end
	local ids = {}
	for id in pairs(servers) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local key = key_of(id)
		if key then return key end
	end
	return ""
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
