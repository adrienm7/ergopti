--- infra/managed_redirect_policy.lua

--- ==============================================================================
--- MODULE: Installed Shared Redirect Policy Binding
--- DESCRIPTION:
--- Preserves bounded native observations and exact ownership receipts.
--- ==============================================================================

--- Lazy installed-layout binding; ordinary no-follow requests do not load it.
local M = {}
local Paths = require("infra.paths")
local Json = require("json")
local Shared = require("network.http_redirect")
local initialized, policy, refusal = false, nil, nil
-- Exceptional configuration-close debt remains owned by this one-time loader.
-- No bare native close retry or policy reload follows an ambiguous close.
local retained = {}

local function read(relative)
	local resolved, path = pcall(Paths.shared, relative)
	if not resolved or type(path) ~= "string" or path == "" or path:find("%z") then return nil end
	local opened, file = pcall(io.open, path, "rb")
	if not opened or not file then return nil end
	retained[file] = true
	local read_ok, bytes = pcall(file.read, file, 32769)
	local close_ok, closed, close_error, close_status = pcall(file.close, file)
	if close_ok and closed == true and close_error == nil and close_status == nil then retained[file] = nil end
	if not read_ok or type(bytes) ~= "string" or #bytes > 32768
		or not close_ok or closed ~= true or close_error ~= nil or close_status ~= nil then return nil end
	local decoded, data = pcall(Json.decode, bytes)
	return decoded and type(data) == "table" and data or nil
end

function M.load()
	if initialized then return policy, refusal end
	initialized = true
	local redirect = read("data/http/redirect_policy.json")
	local transport = redirect and read("data/http/transport_policy.json")
	if not redirect or not transport then refusal = "HTTP redirect policy unavailable"; return nil, refusal end
	local constructed, value, error_code = pcall(Shared.new, redirect, transport)
	if not constructed then refusal = "HTTP redirect policy unavailable"; return nil, refusal end
	policy, refusal = value, error_code
	return policy, refusal
end

return M
