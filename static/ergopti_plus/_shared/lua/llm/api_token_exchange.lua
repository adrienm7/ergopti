--- _shared/lua/llm/api_token_exchange.lua

--- ==============================================================================
--- MODULE: API Token Exchange
--- DESCRIPTION:
--- Some providers take no static key in their requests: IBM watsonx wants an
--- IAM access token exchanged from the user's API key, Google Vertex AI an
--- OAuth access token refreshed from the user's credentials. Both tokens last
--- about an hour. api_providers.json describes the exchange in a provider's
--- auth block; this module builds the exchange request from the stored key,
--- reads the answer and says when a token must be refreshed. The drivers own
--- the HTTP call, the cache and the timer.
---
--- FEATURES & RATIONALE:
--- 1. Declarative: auth = { kind = "token_exchange", token_url, body,
---    token_field, expires_field, default_expires_seconds,
---    refresh_margin_seconds }. body is a form (application/x-www-form-
---    urlencoded) whose values may be {key}, the stored key, or
---    {key.<field>}, a string field of the stored key read as a JSON object
---    (Google's authorized_user credentials file).
--- 2. Every value is percent-encoded, so a key cannot add a form field.
--- 3. Pure: no key or token reaches a log from here; replayed by
---    _shared/tests/corpus/llm/api_token_exchange_vectors.json.
--- ==============================================================================

local M = {}

local Json = require("json")

-- Bounds of the lifetimes, in seconds: an answer outside them is brought
-- back inside, so a token is never refreshed on every request.
M.MIN_EXPIRES_SECONDS = 60
M.MAX_EXPIRES_SECONDS = 86400

local FIELD_NAME = "^[%a_][%w_]*$"




-- ====================================
-- ====================================
-- ======= 1/ Catalogue Block =========
-- ====================================
-- ====================================

--- Reads a provider's auth block.
--- @param raw any providers.<id>.auth; nil when the provider sends its key as is.
--- @return table|nil auth The validated block, nil when absent or refused.
--- @return string|nil reason Why the block is refused.
function M.parse(raw)
	if raw == nil then return nil, nil end
	if type(raw) ~= "table" then return nil, "auth must be an object" end
	if raw.kind ~= "token_exchange" then return nil, "auth.kind must be token_exchange" end
	if type(raw.token_url) ~= "string" or not raw.token_url:match("^https://[^%s{}]+$") then
		return nil, "auth.token_url must be an https address"
	end
	if type(raw.body) ~= "table" or next(raw.body) == nil then return nil, "auth.body must be a non-empty object" end
	local uses_key = false
	for name, value in pairs(raw.body) do
		if type(name) ~= "string" or not name:match(FIELD_NAME) or type(value) ~= "string" then
			return nil, "auth.body fields must be names holding strings"
		end
		for placeholder in value:gmatch("{([^}]*)}") do
			local field = placeholder:match("^key%.(.+)$")
			if placeholder ~= "key" and not (field and field:match(FIELD_NAME)) then
				return nil, "auth.body." .. name .. " holds an unknown placeholder {" .. placeholder .. "}"
			end
			uses_key = true
		end
	end
	if not uses_key then return nil, "auth.body never reads the key" end
	for _, field in ipairs({ "token_field", "expires_field" }) do
		if type(raw[field]) ~= "string" or not raw[field]:match(FIELD_NAME) then
			return nil, "auth." .. field .. " must be a field name"
		end
	end
	local default, margin = raw.default_expires_seconds, raw.refresh_margin_seconds
	if type(default) ~= "number" or default % 1 ~= 0
		or default < M.MIN_EXPIRES_SECONDS or default > M.MAX_EXPIRES_SECONDS then
		return nil, "auth.default_expires_seconds must be a whole number of seconds in bounds"
	end
	if type(margin) ~= "number" or margin % 1 ~= 0 or margin < 0 or margin * 2 >= default then
		return nil, "auth.refresh_margin_seconds must be a whole number below half the default lifetime"
	end
	local body = {}
	for name, value in pairs(raw.body) do body[name] = value end
	return {
		kind = raw.kind, token_url = raw.token_url, body = body,
		token_field = raw.token_field, expires_field = raw.expires_field,
		default_expires_seconds = default, refresh_margin_seconds = margin,
	}, nil
end




-- ====================================
-- ====================================
-- ======= 2/ Exchange ================
-- ====================================
-- ====================================

--- Percent-encodes one form value (RFC 3986 unreserved characters kept).
--- @param text string
--- @return string
local function form_encode(text)
	return (text:gsub("[^%w%-%._~]", function(char) return string.format("%%%02X", char:byte()) end))
end

--- The exchange request of one stored key.
--- @param auth table parse() output.
--- @param key any The stored key.
--- @return table|nil request { url, headers, body }, the body form-encoded with its fields sorted.
--- @return string|nil reason Why the key cannot fill the body (never the key itself).
function M.request(auth, key)
	if type(auth) ~= "table" then error("api_token_exchange.request requires a parsed auth block", 2) end
	if type(key) ~= "string" or key == "" then return nil, "the key is empty" end
	local fields
	local names = {}
	for name in pairs(auth.body) do names[#names + 1] = name end
	table.sort(names)
	local pairs_out = {}
	for _, name in ipairs(names) do
		local missing
		local value = auth.body[name]:gsub("{([^}]*)}", function(placeholder)
			if placeholder == "key" then return key end
			if fields == nil then
				local decoded = key:match("^%s*{") and Json.decode(key) or nil
				fields = type(decoded) == "table" and decoded or false
			end
			local field = placeholder:sub(5)
			local found = fields and fields[field]
			if type(found) ~= "string" or found == "" then
				missing = missing or field
				return ""
			end
			return found
		end)
		if missing then return nil, "the key holds no " .. missing .. " field" end
		pairs_out[#pairs_out + 1] = form_encode(name) .. "=" .. form_encode(value)
	end
	return {
		url = auth.token_url,
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded", Accept = "application/json" },
		body = table.concat(pairs_out, "&"),
	}, nil
end

--- Reads the answer of an exchange.
--- @param auth table parse() output.
--- @param status any The HTTP status.
--- @param decoded any The decoded JSON body.
--- @param now number The current time, in seconds.
--- @return table|nil token { token, expires_at }.
--- @return string|nil reason Why the answer is refused (never its content).
function M.read(auth, status, decoded, now)
	if type(auth) ~= "table" or type(now) ~= "number" then
		error("api_token_exchange.read requires a parsed auth block and the time", 2)
	end
	if status ~= 200 then return nil, "the token exchange answered HTTP " .. tostring(status) end
	if type(decoded) ~= "table" then return nil, "the token exchange answered no JSON object" end
	local token = decoded[auth.token_field]
	if type(token) ~= "string" or token == "" or token:find("[%c%s]") then
		return nil, "the token exchange answered no " .. auth.token_field
	end
	local lifetime = decoded[auth.expires_field]
	if type(lifetime) ~= "number" or lifetime % 1 ~= 0 then lifetime = auth.default_expires_seconds end
	lifetime = math.max(M.MIN_EXPIRES_SECONDS, math.min(M.MAX_EXPIRES_SECONDS, lifetime))
	return { token = token, expires_at = now + lifetime }, nil
end

--- Whether a cached token may still be sent.
--- @param auth table parse() output.
--- @param cached any read() output.
--- @param now number
--- @return boolean usable Not yet expired.
--- @return boolean refresh Within the refresh margin, or unusable: exchange again.
function M.state(auth, cached, now)
	if type(cached) ~= "table" or type(cached.expires_at) ~= "number" then return false, true end
	local usable = now < cached.expires_at
	return usable, now >= cached.expires_at - auth.refresh_margin_seconds
end

return M
