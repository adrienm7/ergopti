--- adapters/json_codec.lua

--- ==============================================================================
--- MODULE: JsonCodec Adapter (Hammerspoon)
--- DESCRIPTION:
--- Wraps hs.json.encode and hs.json.decode behind a stable two-value tuple
--- API so domain modules (LLM backends, config loaders) can serialize and
--- deserialize JSON without a direct dependency on hs.json. The adapter
--- internalizes native exceptions and hs.json.decode's nil-on-error behavior.
--- Callers inspect the error result because a successful JSON null also maps
--- to a nil Lua value.
---
--- FEATURES & RATIONALE:
--- 1. Two-value contract: encode/decode return (value, nil) on success and
---    (nil, error_string) on failure. The error slot is authoritative for
---    decode because valid top-level null is represented as (nil, nil).
--- 2. No state: both functions are pure pass-throughs to hs.json; the adapter
---    holds no module-level state and is safe to require from any thread.
--- 3. Nil-safe: passing nil to either function returns (nil, "nil input")
---    immediately rather than letting hs.json raise an exception.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.json_codec"


--- Returns whether the source is exactly a JSON null with optional JSON whitespace.
--- @param json_str string Raw JSON source.
--- @return boolean is_null True only for a valid top-level null token shape.
local function is_json_null_literal(json_str)
	return json_str:match("^[ \t\r\n]*null[ \t\r\n]*$") ~= nil
end


--- Encodes a Lua table (or scalar) to a JSON string.
--- @param value any Value to encode — must be a table, string, number, or boolean.
--- @return string|nil encoded JSON string, or nil on failure.
--- @return string|nil err Error description, or nil on success.
function M.encode(value)
	if value == nil then
		return nil, "nil input"
	end
	local ok, result = pcall(hs.json.encode, value)
	if not ok then
		Logger.error(LOG, "encode() failed: %s", tostring(result))
		return nil, tostring(result)
	end
	return result, nil
end

--- Decodes a JSON string to a Lua value.
--- @param json_str string JSON string to decode.
--- @return any|nil decoded Lua value, nil for JSON null, or nil on failure.
--- @return string|nil err Error description on failure; nil means success.
function M.decode(json_str)
	if type(json_str) ~= "string" or json_str == "" then
		return nil, "empty or non-string input"
	end
	local ok, result = pcall(hs.json.decode, json_str)
	if not ok then
		Logger.error(LOG, "decode() failed: %s", tostring(result))
		return nil, tostring(result)
	end
	if result == nil and not is_json_null_literal(json_str) then
		local detail = "native JSON decoder returned no value."
		Logger.error(LOG, "decode() failed: %s", detail)
		return nil, detail
	end
	return result, nil
end

return M
