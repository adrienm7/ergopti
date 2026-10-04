--- infra/http_transport_policy.lua

--- ==============================================================================
--- MODULE: Linux HTTP Transport Policy Binding
--- DESCRIPTION:
--- Binds the shared HTTP scheme inventory to URL preflight and curl's native
--- protocol fence. File/protocol bytes must never reach stream callbacks or
--- download files before an eventual missing HTTP status reports failure.
--- ==============================================================================

local M = {}

local Json = require("json")
local Paths = require("infra.paths")

local _schemes = nil
local _protocols = nil


-- =========================================
-- =========================================
-- ======= 1/ Shared Policy ================
-- =========================================
-- =========================================

--- Reads and validates the canonical HTTP scheme inventory.
--- @return table|nil schemes, string|nil error
local function load_schemes()
	if _schemes then return _schemes end
	local path = Paths.shared("data/http/transport_policy.json")
	local file = path and io.open(path, "rb")
	if not file then return nil, "HTTP transport policy is unavailable" end
	local bytes = file:read("*a")
	local closed = file:close()
	if not bytes or not closed then return nil, "HTTP transport policy cannot be read" end
	local ok, policy = pcall(Json.decode, bytes)
	local names = ok and type(policy) == "table" and policy.allowed_schemes
	if type(names) ~= "table" or #names == 0 then return nil, "HTTP transport policy is invalid" end
	local schemes = {}
	for index, name in pairs(names) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #names
			or type(name) ~= "string" or not name:match("^[a-z][a-z0-9+%.%-]*$") or schemes[name] then
			return nil, "HTTP transport policy is invalid"
		end
		schemes[name] = true
	end
	_protocols = "=" .. table.concat(names, ",")
	_schemes = schemes
	return schemes
end

--- Refuses unsupported URL schemes and returns curl's exact protocol fence.
--- @param url string Absolute request URL.
--- @param https_only boolean|nil Additional caller constraint.
--- @return string|nil protocols, string|nil error
function M.resolve(url, https_only)
	local schemes, err = load_schemes()
	if not schemes then return nil, err end
	local scheme = url:match("^([%a][%w+%.%-]*)://")
	if not scheme or not schemes[scheme:lower()] then return nil, "HTTP URL protocol is unsupported" end
	if https_only then
		if not schemes.https then return nil, "HTTP transport policy does not allow HTTPS" end
		return "=https"
	end
	return _protocols
end

return M
