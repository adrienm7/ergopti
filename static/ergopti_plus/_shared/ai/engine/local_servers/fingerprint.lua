--- _shared/ai/engine/local_servers/fingerprint.lua

--- ==============================================================================
--- MODULE: Local Server Fingerprint
--- DESCRIPTION:
--- Two catalogue rows may share a default address (oMLX and vLLM on 8000,
--- text-generation-webui and TabbyAPI on 5000). The OpenAI models listing is
--- the same shape for both, but each project fills the owned_by field of its
--- model objects with its own value. This module reads those declared values
--- (servers.<id>.fingerprint in local_servers.json) and decides which row of
--- a shared address actually answered, so the menu names the real server and
--- one answering address never shows as two rows. Pure: the discovery
--- controller (llm.local_server_discovery) calls it on the bodies it settles
--- and keeps one row per answering address.
--- ==============================================================================

local M = {}
local Json = require("core.text.engine.json")





-- =====================================
-- =====================================
-- ======= 1/ Catalogue ================
-- =====================================
-- =====================================

--- Validates one declared fingerprint rule.
--- @param id string Server id.
--- @param raw any servers.<id>.fingerprint.
--- @return table|nil rule { model_field, equals }
--- @return string|nil reason
local function parse_rule(id, raw)
	if type(raw) ~= "table" or Json.is_array(raw) then return nil, id .. ".fingerprint must be an object" end
	if type(raw.model_field) ~= "string" or not raw.model_field:match("^[A-Za-z_][A-Za-z0-9_]*$") then
		return nil, id .. ".fingerprint.model_field must be a field name"
	end
	if type(raw.equals) ~= "string" or raw.equals == "" then
		return nil, id .. ".fingerprint.equals must be a non-empty string"
	end
	return { model_field = raw.model_field, equals = raw.equals }
end

--- Reads the fingerprints of the rows that share a default address.
--- A rule on a row whose address no other row shares is refused: nothing
--- would ever be decided with it.
--- @param root table Decoded local_servers.json.
--- @param order table Admitted catalogue ids in server_order.
--- @return table identities Server id -> { group = ids sharing its address in
---         server_order (the first one is the address's default row), rule? }.
--- @return table errors Reasons a declared rule was refused, in order.
function M.parse(root, order)
	local identities, errors, groups = {}, {}, {}
	local servers = type(root) == "table" and type(root.servers) == "table" and root.servers or {}
	for _, id in ipairs(order) do
		local address = type(servers[id]) == "table" and servers[id].base_url or nil
		if type(address) == "string" then
			groups[address] = groups[address] or {}
			table.insert(groups[address], id)
		end
	end
	for _, id in ipairs(order) do
		local server = servers[id]
		local group = type(server) == "table" and groups[server.base_url] or nil
		if group and #group > 1 then
			local rule, reason = nil, nil
			if server.fingerprint ~= nil then rule, reason = parse_rule(id, server.fingerprint) end
			if reason then errors[#errors + 1] = reason end
			local copy = {}
			for index, member in ipairs(group) do copy[index] = member end
			identities[id] = { group = copy, rule = rule }
		elseif type(server) == "table" and server.fingerprint ~= nil then
			errors[#errors + 1] = id .. ".fingerprint is declared on an address no other row shares"
		end
	end
	-- Two rows of one address with the same rule could never be told apart
	for id, identity in pairs(identities) do
		for _, other in ipairs(identity.group) do
			local mine, theirs = identity.rule, identities[other] and identities[other].rule
			if other < id and mine and theirs and mine.model_field == theirs.model_field and mine.equals == theirs.equals then
				errors[#errors + 1] = id .. ".fingerprint repeats the one of " .. other
				identity.rule, identities[other].rule = nil, nil
			end
		end
	end
	table.sort(errors)
	return identities, errors
end





-- =====================================
-- =====================================
-- ======= 2/ Identification ===========
-- =====================================
-- =====================================

--- Names the row of a shared address whose fingerprint a models body carries.
--- @param body any The raw models response body.
--- @param id string The row that was probed.
--- @param identities table Output of M.parse.
--- @return string|nil server The fingerprinted row; nil when none decides.
--- @return string reason "match", "unshared", "invalid", "unknown" or "ambiguous".
function M.identify(body, id, identities)
	local identity = type(identities) == "table" and identities[id] or nil
	if not identity then return nil, "unshared" end
	local root = type(body) == "string" and Json.decode_lossless(body) or nil
	if type(root) ~= "table" or Json.is_array(root) or not Json.is_array(root.data) then return nil, "invalid" end
	local found = nil
	for _, candidate in ipairs(identity.group) do
		local rule = identities[candidate] and identities[candidate].rule
		local matched = false
		if rule then
			for _, model in ipairs(root.data) do
				if type(model) == "table" and model[rule.model_field] == rule.equals then matched = true; break end
			end
		end
		if matched then
			if found then return nil, "ambiguous" end
			found = candidate
		end
	end
	if not found then return nil, "unknown" end
	return found, "match"
end

return M
