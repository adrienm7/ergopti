--- _shared/lua/keystats/manifest_keys.lua

--- ==============================================================================
--- MODULE: Metrics Manifest Application Keys
--- DESCRIPTION:
--- Encodes application identities without colliding with system rows. Shared
--- vectors pin the JavaScript and Windows ports to this representation.
--- ==============================================================================
local M = {}

--- Encodes an exact application label as a manifest key.
--- @param name string Original application label.
--- @return string key Collision-free manifest key.
function M.encode(name)
	assert(type(name) == "string", "manifest application name must be text")
	if name == "_system" or name == "_sys" or name:sub(1, 1) == "~" then return "~" .. name end
	return name
end

--- Decodes a non-system manifest key to its exact application label.
--- @param key string Encoded application key.
--- @return string name Original application label.
function M.decode(key)
	assert(type(key) == "string", "manifest application key must be text")
	return key:sub(1, 1) == "~" and key:sub(2) or key
end

return M
