--- infra/http_header_policy.lua

--- ==============================================================================
--- MODULE: Native HTTP Header Policy
--- DESCRIPTION:
--- Loads the shared forbidden-byte law and applies the Hammerspoon ASCII boundary.
--- ==============================================================================

local M = {}
local cached

-- Shared policy.

--- Reads and validates the shared forbidden-byte inventory.
--- @return table|nil bytes, string|nil error
local function forbidden_bytes()
	if cached then return cached end
	local Paths = require("infra.paths")
	local FileSystem = require("adapters.file_system")
	local path = Paths.shared("core/network/data/http/header_policy.json")
	if not path then return nil, "HTTP header policy is unavailable" end
	local content, status = FileSystem.read_bounded(path, 4096)
	if status ~= "ok" or type(content) ~= "string" then return nil, "HTTP header policy is unavailable" end
	local ok, policy = pcall(require("core.text.engine.json").decode, content)
	local bytes = ok and type(policy) == "table" and policy.forbidden_bytes
	if type(bytes) ~= "table" or #bytes == 0 then return nil, "HTTP header policy is invalid" end
	local result, count = {}, 0
	for index, byte in pairs(bytes) do
		if math.type(index) ~= "integer" or index < 1 or index > #bytes
			or math.type(byte) ~= "integer" or byte < 0 or byte > 255 or result[byte] then
			return nil, "HTTP header policy is invalid"
		end
		result[byte] = string.char(byte)
		count = count + 1
	end
	if count ~= #bytes then return nil, "HTTP header policy is invalid" end
	cached = result
	return result
end

-- Native header admission.

--- Validates caller header strings before hs.http converts them through ASCII.
--- @param name string Header name.
--- @param value string Header value.
--- @return boolean allowed
--- @return string|nil reason
function M.validate(name, value)
	if type(name) ~= "string" or type(value) ~= "string" then
		return false, "HTTP header names and values must be strings"
	end
	local bytes, err = forbidden_bytes()
	if not bytes then return false, err end
	for _, byte in pairs(bytes) do
		if name:find(byte, 1, true) or value:find(byte, 1, true) then
			return false, "HTTP header contains a forbidden byte"
		end
	end
	if name:find("[\128-\255]") or value:find("[\128-\255]") then
		return false, "HTTP header cannot be represented by the native ASCII bridge"
	end
	return true
end

return M
