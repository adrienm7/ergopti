--- infra/proxy_policy.lua

--- ==============================================================================
--- MODULE: Linux Native Proxy Policy Binding
--- DESCRIPTION:
--- Resolves and initializes the canonical shared routing policy through the
--- existing native path/file owners. No OS-specific routing fallback is stored.
--- ==============================================================================

local M = {}
local Paths = require("infra.paths")
local Json = require("json")
local SharedPolicy = require("network.proxy_policy")
local initialized, policy, refusal = false, nil, nil

--- Loads the shared canonical routing inventory exactly once.
--- @return table|nil
--- @return string|nil
function M.load()
	if initialized then return policy, refusal end
	initialized = true
	local path = Paths.shared("modules/network/proxy_policy.json")
	local file = path and io.open(path, "rb")
	if not file then refusal = "proxy-policy-unavailable"; return nil, refusal end
	local bytes = file:read(32769)
	local closed = file:close()
	if type(bytes) ~= "string" or #bytes > 32768 or not closed then
		refusal = "proxy-policy-unavailable"
		return nil, refusal
	end
	local decoded, data = pcall(Json.decode, bytes)
	if not decoded then refusal = "proxy-policy-invalid"; return nil, refusal end
	policy, refusal = SharedPolicy.new(data)
	return policy, refusal
end

--- Reads only the privately consumed environment fields declared by policy.
--- @return table
function M.environment()
	local active, err = M.load()
	if not active then error(err, 2) end
	local snapshot = {}
	for _, name in ipairs(active.environment_names()) do snapshot[name] = os.getenv(name) end
	return snapshot
end

return M
