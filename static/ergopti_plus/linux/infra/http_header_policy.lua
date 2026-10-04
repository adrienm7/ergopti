--- infra/http_header_policy.lua

--- ==============================================================================
--- MODULE: Linux HTTP Header Policy Binding
--- DESCRIPTION:
--- Loads the shared header byte boundary. Curl config escapes protect config
--- syntax, but curl decodes them before constructing headers: CR/LF can still
--- inject another wire header. Missing or invalid policy is a refusal.
--- ==============================================================================

local M = {}

local Json = require("json")
local Paths = require("infra.paths")

local _bytes = nil


-- =========================================
-- =========================================
-- ======= 1/ Shared Policy ================
-- =========================================
-- =========================================

--- Reads and validates the canonical forbidden-byte inventory.
--- @return table|nil bytes, string|nil error
local function load_bytes()
	if _bytes then return _bytes end
	local path = Paths.shared("data/http/header_policy.json")
	local file = path and io.open(path, "rb")
	if not file then return nil, "HTTP header policy is unavailable" end
	local content = file:read("*a")
	local closed = file:close()
	if not content or not closed then return nil, "HTTP header policy cannot be read" end
	local ok, policy = pcall(Json.decode, content)
	local inventory = ok and type(policy) == "table" and policy.forbidden_bytes
	if type(inventory) ~= "table" or #inventory == 0 then return nil, "HTTP header policy is invalid" end
	local bytes = {}
	for index, byte in pairs(inventory) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #inventory
			or type(byte) ~= "number" or byte % 1 ~= 0 or byte < 0 or byte > 255 or bytes[byte] then
			return nil, "HTTP header policy is invalid"
		end
		bytes[byte] = string.char(byte)
	end
	_bytes = bytes
	return bytes
end

--- Validates serialized header bytes before config escaping or native effects.
--- @param name string
--- @param value string
--- @return boolean|nil allowed, string|nil error
function M.validate(name, value)
	local bytes, err = load_bytes()
	if not bytes then return nil, err end
	for _, byte in pairs(bytes) do
		if name:find(byte, 1, true) or value:find(byte, 1, true) then
			return false, "HTTP header contains a forbidden byte"
		end
	end
	return true
end

return M
