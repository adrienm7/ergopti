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
--- 4. Signed assertion (RFC 7523): an optional auth.assertion = { key_type,
---    body, issuer_field, private_key_field, key_id_field, scope,
---    lifetime_seconds } takes a stored key whose JSON type is key_type (a
---    Google service-account key): its body's {assertion} is a JWT signed
---    RS256 with the key's private_key (crypto/rsa_pkcs1.lua), addressed to
---    token_url. The key file's own token_uri is never followed, so a key
---    cannot send its assertion elsewhere.
--- 5. A signature takes a few hundred milliseconds of pure Lua on macOS:
---    begin() returns a job whose step() signs one slice of a few
---    milliseconds, so the drivers spread it over timer ticks and never
---    hold the keyboard's event loop.
--- ==============================================================================

local M = {}

local Base64 = require("compat.base64")
local Json = require("json")
local Rsa = require("crypto.rsa_pkcs1")
local TableUtil = require("table_util")
local TextUtils = require("text_utils")

-- Bounds of the lifetimes, in seconds: an answer outside them is brought
-- back inside, so a token is never refreshed on every request.
M.MIN_EXPIRES_SECONDS = 60
M.MAX_EXPIRES_SECONDS = 86400
-- The longest signed assertion: Google refuses one valid over an hour
-- (RFC 7523 leaves it to the token service)
M.MAX_ASSERTION_SECONDS = 3600
-- The longest service message a refusal carries, in bytes: enough for an
-- OAuth or IAM sentence, never a whole error page
M.MAX_SERVICE_MESSAGE_BYTES = 200

local FIELD_NAME = "^[%a_][%w_]*$"




-- ====================================
-- ====================================
-- ======= 1/ Catalogue Block =========
-- ====================================
-- ====================================

--- Reads a form body block.
--- @param raw any
--- @param where string Its name in the reasons.
--- @param signed boolean Whether {assertion} is the placeholder it must hold.
--- @return table|nil body A copy, nil when refused.
--- @return string|nil reason
local function parse_body(raw, where, signed)
	if type(raw) ~= "table" or next(raw) == nil then return nil, where .. " must be a non-empty object" end
	local uses_key = false
	local body = {}
	for name, value in pairs(raw) do
		if type(name) ~= "string" or not name:match(FIELD_NAME) or type(value) ~= "string" then
			return nil, where .. " fields must be names holding strings"
		end
		for placeholder in value:gmatch("{([^}]*)}") do
			local field = placeholder:match("^key%.(.+)$")
			local known
			if signed then known = placeholder == "assertion"
			else known = placeholder == "key" or (field ~= nil and field:match(FIELD_NAME) ~= nil) end
			if not known then
				return nil, where .. "." .. name .. " holds an unknown placeholder {" .. placeholder .. "}"
			end
			uses_key = true
		end
		body[name] = value
	end
	if not uses_key then
		return nil, where .. (signed and " never reads the assertion" or " never reads the key")
	end
	return body, nil
end

--- Reads the signed-assertion block of an auth block.
--- @param raw any auth.assertion
--- @return table|nil assertion, string|nil reason
local function parse_assertion(raw)
	if type(raw) ~= "table" then return nil, "auth.assertion must be an object" end
	if type(raw.key_type) ~= "string" or not raw.key_type:match(FIELD_NAME) then
		return nil, "auth.assertion.key_type must be a key type name"
	end
	local body, reason = parse_body(raw.body, "auth.assertion.body", true)
	if not body then return nil, reason end
	for _, field in ipairs({ "issuer_field", "private_key_field" }) do
		if type(raw[field]) ~= "string" or not raw[field]:match(FIELD_NAME) then
			return nil, "auth.assertion." .. field .. " must be a field name"
		end
	end
	if raw.key_id_field ~= nil and (type(raw.key_id_field) ~= "string" or not raw.key_id_field:match(FIELD_NAME)) then
		return nil, "auth.assertion.key_id_field must be a field name"
	end
	if type(raw.scope) ~= "string" or not raw.scope:match("^https://[^%s{}]+$") then
		return nil, "auth.assertion.scope must be an https scope"
	end
	local lifetime = raw.lifetime_seconds
	if type(lifetime) ~= "number" or lifetime % 1 ~= 0
		or lifetime < M.MIN_EXPIRES_SECONDS or lifetime > M.MAX_ASSERTION_SECONDS then
		return nil, "auth.assertion.lifetime_seconds must be a whole number of seconds in bounds"
	end
	return {
		key_type = raw.key_type, body = body, issuer_field = raw.issuer_field,
		private_key_field = raw.private_key_field, key_id_field = raw.key_id_field,
		scope = raw.scope, lifetime_seconds = lifetime,
	}, nil
end

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
	local body, body_reason = parse_body(raw.body, "auth.body", false)
	if not body then return nil, body_reason end
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
	local assertion
	if raw.assertion ~= nil then
		local reason
		assertion, reason = parse_assertion(raw.assertion)
		if not assertion then return nil, reason end
	end
	return {
		kind = raw.kind, token_url = raw.token_url, body = body,
		token_field = raw.token_field, expires_field = raw.expires_field,
		default_expires_seconds = default, refresh_margin_seconds = margin,
		assertion = assertion,
	}, nil
end




-- ====================================
-- ====================================
-- ======= 2/ Exchange ================
-- ====================================
-- ====================================

--- The stored key read as a JSON object, false when it is none.
--- @param key string
--- @return table|false
local function key_fields(key)
	local decoded = key:match("^%s*{") and Json.decode(key) or nil
	return type(decoded) == "table" and decoded or false
end

--- Fills and form-encodes a body block.
--- @param body table A parsed body: field -> template.
--- @param fill function fill(placeholder) -> string|nil, nil naming a missing field.
--- @return string|nil form The fields sorted, each name and value percent-encoded.
--- @return string|nil missing The first placeholder that had no value.
local function encode_form(body, fill)
	local out = {}
	for _, name in ipairs(TableUtil.sorted_keys(body)) do
		local missing
		local value = body[name]:gsub("{([^}]*)}", function(placeholder)
			local found = fill(placeholder)
			if found == nil then
				missing = missing or placeholder
				return ""
			end
			return found
		end)
		if missing then return nil, missing end
		out[#out + 1] = TextUtils.percent_encode(name) .. "=" .. TextUtils.percent_encode(value)
	end
	return table.concat(out, "&"), nil
end

--- The request of a filled form.
--- @param auth table
--- @param form string
--- @return table request
local function form_request(auth, form)
	return {
		url = auth.token_url,
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded", Accept = "application/json" },
		body = form,
	}
end

--- A string field of the stored key's JSON, nil when absent or empty.
--- @param fields table|false
--- @param name string
--- @return string|nil
local function key_string(fields, name)
	local found = fields and fields[name]
	if type(found) ~= "string" or found == "" then return nil end
	return found
end

--- base64url without padding (RFC 7515 2).
--- @param bytes string
--- @return string
local function base64url(bytes)
	return (Base64.encode(bytes):gsub("[+/=]", { ["+"] = "-", ["/"] = "_", ["="] = "" }))
end

--- The unsigned JWT of an assertion: header and claims in a fixed order, so
--- the same key and time always give the same bytes.
--- @param auth table
--- @param fields table The stored key's JSON.
--- @param unix_now integer
--- @return string|nil input header.claims, string|nil reason
local function assertion_input(auth, fields, unix_now)
	local spec = auth.assertion
	local issuer = key_string(fields, spec.issuer_field)
	if not issuer then return nil, "the key holds no " .. spec.issuer_field .. " field" end
	local header = '{"alg":"RS256","typ":"JWT"'
	local key_id = spec.key_id_field and key_string(fields, spec.key_id_field) or nil
	if key_id then header = header .. ',"kid":' .. Json.quote(key_id) end
	header = header .. "}"
	local claims = string.format('{"iss":%s,"scope":%s,"aud":%s,"iat":%d,"exp":%d}',
		Json.quote(issuer), Json.quote(spec.scope), Json.quote(auth.token_url),
		unix_now, unix_now + spec.lifetime_seconds)
	return base64url(header) .. "." .. base64url(claims), nil
end

--- A job settled from the start.
--- @return table job
local function settled_job(request, reason)
	return { step = function() return true, request, reason end }
end

--- Starts the exchange request of one stored key. A key that needs no
--- signature settles on the first step(); a signed assertion takes one
--- slice of its signature per step(), so a caller can yield between them.
--- @param auth table parse() output.
--- @param key any The stored key.
--- @param unix_now integer The wall-clock time, in whole seconds since 1970 (a JWT's iat).
--- @return table job { step } -- step() -> settled, request|nil, reason|nil; request is
---   { url, headers, body }, the body form-encoded with its fields sorted; reason never
---   holds the key.
function M.begin(auth, key, unix_now)
	if type(auth) ~= "table" then error("api_token_exchange.begin requires a parsed auth block", 2) end
	if type(unix_now) ~= "number" or unix_now % 1 ~= 0 or unix_now < 0 then
		error("api_token_exchange.begin requires the wall-clock time in whole seconds", 2)
	end
	if type(key) ~= "string" or key == "" then return settled_job(nil, "the key is empty") end
	local fields = nil
	local spec = auth.assertion
	if spec then
		fields = key_fields(key)
		if not (fields and fields.type == spec.key_type) then spec = nil end
	end
	if not spec then
		local form, missing = encode_form(auth.body, function(placeholder)
			if placeholder == "key" then return key end
			if fields == nil then fields = key_fields(key) end
			return key_string(fields, placeholder:sub(5))
		end)
		if not form then return settled_job(nil, "the key holds no " .. missing:sub(5) .. " field") end
		return settled_job(form_request(auth, form), nil)
	end
	local worker = coroutine.create(function()
		local pem = key_string(fields, spec.private_key_field)
		if not pem then return nil, "the key holds no " .. spec.private_key_field .. " field" end
		local input, input_reason = assertion_input(auth, fields, unix_now)
		if not input then return nil, input_reason end
		local private_key, key_reason = Rsa.read_private_key(pem)
		if not private_key then return nil, key_reason end
		local signature, sign_reason = Rsa.sign_sha256(private_key, input, coroutine.yield)
		if not signature then return nil, sign_reason end
		local jwt = input .. "." .. base64url(signature)
		local form = encode_form(spec.body, function() return jwt end)
		return form_request(auth, form), nil
	end)
	local settled, request, reason = false, nil, nil
	return {
		step = function()
			if settled then return true, request, reason end
			local resumed, first, second = coroutine.resume(worker)
			-- A fault inside the signer is a bug, never a refusal to hide
			if not resumed then error("api_token_exchange signer failed: " .. tostring(first), 0) end
			if coroutine.status(worker) ~= "dead" then return false, nil, nil end
			settled, request, reason = true, first, second
			return true, request, reason
		end,
	}
end

--- Runs a begin() job to its end: the first step at once, then one step per
--- driver tick, so a signature never holds the event loop for more than a
--- slice. A key needing no signature settles before drive() returns.
--- @param job table begin() output.
--- @param schedule function schedule(fn) -> boolean, true once fn is armed for the next tick.
--- @param on_settled function on_settled(request|nil, reason|nil), called exactly once.
function M.drive(job, schedule, on_settled)
	if type(job) ~= "table" or type(job.step) ~= "function" or type(schedule) ~= "function"
		or type(on_settled) ~= "function" then
		error("api_token_exchange.drive requires a job, a scheduler and a callback", 2)
	end
	local finished = false
	local function finish(request, reason)
		if finished then return end
		finished = true
		return on_settled(request, reason)
	end
	local function tick()
		if finished then return end
		local stepped, settled, request, reason = pcall(job.step)
		-- A signer fault settles the exchange as refused with its cause, so the
		-- token slot never stays pending; the cause holds no key material
		if not stepped then return finish(nil, "the assertion signer failed: " .. tostring(settled)) end
		if settled then return finish(request, reason) end
		-- A scheduler can throw after retaining the callback. Revoke that exact
		-- callback on refusal so a late tick cannot send a second exchange.
		local active = true
		local called, armed = pcall(schedule, function() if active then tick() end end)
		if not called or armed ~= true then
			active = false
			return finish(nil, "the assertion signature could not be resumed")
		end
	end
	tick()
end

--- The exchange request of one stored key, its signature (if any) made at once.
--- @param auth table parse() output.
--- @param key any The stored key.
--- @param unix_now integer Whole seconds since 1970.
--- @return table|nil request { url, headers, body }.
--- @return string|nil reason Why the key cannot fill the body (never the key itself).
function M.request(auth, key, unix_now)
	local job = M.begin(auth, key, unix_now)
	while true do
		local settled, request, reason = job.step()
		if settled then return request, reason end
	end
end

--- The message a refusing token service gives, in the field its error format
--- uses (OAuth error_description and error, IAM errorMessage, Google's
--- error.message), flattened to one bounded line; nil when it gives none. A
--- refusal is then explained by the service rather than by its status alone.
--- @param decoded any The decoded JSON body.
--- @return string|nil message
local function service_message(decoded)
	if type(decoded) ~= "table" then return nil end
	local nested = type(decoded.error) == "table" and decoded.error.message or nil
	-- A fixed count: absent fields are nil holes that ipairs would stop at
	local candidates = { decoded.error_description, decoded.errorMessage, nested, decoded.message, decoded.error }
	for index = 1, 5 do
		local candidate = candidates[index]
		if type(candidate) == "string" then
			local line = TextUtils.trim((candidate:gsub("%c", " "):gsub("%s+", " ")))
			if line ~= "" then return TextUtils.utf8_byte_prefix(line, M.MAX_SERVICE_MESSAGE_BYTES) end
		end
	end
	return nil
end

--- Reads the answer of an exchange.
--- @param auth table parse() output.
--- @param status any The HTTP status.
--- @param decoded any The decoded JSON body.
--- @param now number The current time, in seconds.
--- @return table|nil token { token, expires_at }.
--- @return string|nil reason Why the answer is refused: its status and the service's
---   own message (service_message), never a token.
function M.read(auth, status, decoded, now)
	if type(auth) ~= "table" or type(now) ~= "number" then
		error("api_token_exchange.read requires a parsed auth block and the time", 2)
	end
	if status ~= 200 then
		local refusal = "the token exchange answered HTTP " .. tostring(status)
		local message = service_message(decoded)
		return nil, message and (refusal .. ": " .. message) or refusal
	end
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
