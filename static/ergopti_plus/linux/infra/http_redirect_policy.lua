--- infra/http_redirect_policy.lua

--- ==============================================================================
--- MODULE: Linux HTTP Redirect Policy Binding
--- DESCRIPTION:
--- Loads the shared credential-header inventory through the installed-layout
--- path resolver. Native curl cannot remove arbitrary caller API-key headers
--- at an origin boundary, so credentialed requests must not auto-follow.
--- A missing or invalid policy is a refusal, never an empty credential list.
--- ==============================================================================

local M = {}

local Json = require("json")
local Paths = require("infra.paths")

local _headers = nil


-- =========================================
-- =========================================
-- ======= 1/ Shared Policy ================
-- =========================================
-- =========================================

--- Reads and validates the canonical credential-header inventory.
--- @return table|nil headers, string|nil error
local function load_headers()
	if _headers then return _headers end
	local path = Paths.shared("data/http/redirect_policy.json")
	local file = path and io.open(path, "rb")
	if not file then return nil, "HTTP redirect policy is unavailable" end
	local bytes = file:read("*a")
	local closed = file:close()
	if not bytes or not closed then return nil, "HTTP redirect policy cannot be read" end
	local ok, policy = pcall(Json.decode, bytes)
	local names = ok and type(policy) == "table" and policy.sensitive_headers
	if type(names) ~= "table" or #names == 0 then
		return nil, "HTTP redirect policy is invalid"
	end
	local headers = {}
	for index, name in pairs(names) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #names
			or type(name) ~= "string" or not name:match("^[a-z][a-z0-9%-]*$") or headers[name] then
			return nil, "HTTP redirect policy is invalid"
		end
		headers[name] = true
	end
	_headers = headers
	return headers
end

--- Resolves whether the caller's headers permit native redirect following.
--- @param headers table Header names are case-insensitive.
--- @return boolean|nil allowed, string|nil error
function M.allows_native_follow(headers)
	local sensitive, err = load_headers()
	if not sensitive then return nil, err end
	for name in pairs(headers) do
		if type(name) == "string" and sensitive[name:lower()] then return false end
	end
	return true
end

return M
