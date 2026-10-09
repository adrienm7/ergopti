--- modules/llm/profile_registry_codec.lua

--- Uses the canonical versioned JSON envelope already written by Windows.
local M = {}
local Json = require("json")
local Base64 = require("compat.base64")

local function dense(registry)
	assert(type(registry) == "table", "user profile registry must be an array")
	for index in pairs(registry) do
		assert(type(index) == "number" and index % 1 == 0 and index >= 1 and index <= #registry,
			"user profile registry must be dense")
	end
	for index = 1, #registry do
		assert(registry[index] ~= nil, "user profile registry must not contain holes")
	end
	return registry
end

--- Whether a stored payload is an older build's shape rather than a versioned
--- envelope: text without a "v<N>:" prefix. A newer version or a damaged v1
--- envelope is not outdated: decode() refuses it, so it is never overwritten.
--- @param payload any Stored llm.user_profiles value.
--- @return boolean
function M.is_outdated(payload)
	return type(payload) == "string" and payload ~= "" and payload:match("^v%d+:") == nil
end

--- Decodes declared storage without importing any legacy namespace.
--- @param payload string Canonical v1 envelope or neutral empty string.
--- @return table registry Detached records, including unreadable entries.
function M.decode(payload)
	assert(type(payload) == "string", "user profile registry requires a string")
	if payload == "" then return {} end
	assert(payload:sub(1, 3) == "v1:", "unknown user profile registry version")
	local decoded = assert(Base64.decode(payload:sub(4)), "invalid user profile base64 envelope")
	assert(decoded:match("^%s*%["), "user profile JSON must be an array")
	return dense(Json.decode_lossless(decoded))
end

--- Encodes a detached registry, leaving an empty registry sparse.
--- @param registry table Dense user records.
--- @return string payload Canonical envelope.
function M.encode(registry)
	dense(registry)
	if #registry == 0 then return "" end
	return "v1:" .. Base64.encode(Json.encode(registry))
end

return M
