--- infra/proxy_policy.lua

--- ==============================================================================
--- MODULE: Linux Native Proxy Policy Binding
--- DESCRIPTION:
--- Resolves and initializes the canonical shared routing policy through the
--- existing native path/file owners. No OS-specific routing fallback is stored.
--- Every route decision receives the user's proxy override (Issue #101 point 2,
--- network/proxy_override.lua), read from storage at decision time, so managed
--- downloads and the managed Ollama daemon honour it before the desktop proxy.
--- ==============================================================================

local M = {}
local Paths = require("infra.paths")
local Reader = require("infra.regular_file_reader")
local Json = require("json")
local SharedPolicy = require("network.proxy_policy")
local Override = require("network.proxy_override")
local initialized, policy, refusal = false, nil, nil
local override_initialized, override, override_refusal = false, nil, nil

--- Reads one small shared JSON declaration through the native file owner.
--- @param relative string Path under the shared tree.
--- @param unavailable string Refusal when it cannot be read.
--- @param invalid string Refusal when it is not JSON.
--- @return table|nil data, string|nil reason
local function read_declaration(relative, unavailable, invalid)
	local path = Paths.shared(relative)
	local file = path and Reader.open_source(path)
	if not file then return nil, unavailable end
	local bytes = file:read(32769)
	local closed = file:close()
	if type(bytes) ~= "string" or #bytes > 32768 or not closed then return nil, unavailable end
	local decoded, data = pcall(Json.decode, bytes)
	if not decoded then return nil, invalid end
	return data, nil
end

--- Loads the shared proxy override declaration exactly once.
--- @return table|nil setting, string|nil reason
function M.override_setting()
	if override_initialized then return override, override_refusal end
	override_initialized = true
	local data
	data, override_refusal = read_declaration("modules/network/proxy_override.json",
		"proxy-override-unavailable", Override.DECLARATION_INVALID)
	if data then override, override_refusal = Override.new(data) end
	return override, override_refusal
end

--- The user's current override choice, read from storage now.
--- @return table|nil choice { mode, relay }, string|nil reason
function M.override_choice()
	local setting, reason = M.override_setting()
	if not setting then return nil, reason end
	return setting.parse(require("adapters.storage").get(setting.storage_key, nil))
end

--- Loads the shared canonical routing inventory exactly once.
--- @return table|nil
--- @return string|nil
function M.load()
	if initialized then return policy, refusal end
	initialized = true
	local data
	data, refusal = read_declaration("modules/network/proxy_policy.json", "proxy-policy-unavailable", "proxy-policy-invalid")
	if not data then return nil, refusal end
	local shared
	shared, refusal = SharedPolicy.new(data)
	if not shared then return nil, refusal end
	policy = setmetatable({
		--- Routes one URL with the stored override; an invalid stored value
		--- refuses the download instead of reading as automatic.
		route = function(url, environment)
			local choice, reason = M.override_choice()
			if not choice then return nil, reason end
			return shared.route(url, environment, choice)
		end,
	}, { __index = shared })
	return policy, nil
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
