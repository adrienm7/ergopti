--- adapters/storage.lua

--- ==============================================================================
--- MODULE: Storage Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Storage port contract. Provides a
--- key-value persistent store backed by hs.settings, which persists data
--- across Hammerspoon reloads and system reboots.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: every method returns a safe default on error so
---    callers never receive nil in place of a boolean or table.
--- 2. Defensive pcall: hs.settings calls can raise on some internal states;
---    every call is wrapped in pcall to prevent propagation to domain modules.
--- 3. hs.settings.set returns nil, not true — success is inferred from the
---    absence of an error raised by pcall, not from the return value.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.storage"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Stores a value under the given key in the persistent settings store.
--- @param key string The settings key.
--- @param value any The value to persist.
--- @return boolean True on success, false if the call raised an error.
function M.set(key, value)
	local ok, err = pcall(function()
		hs.settings.set(key, value)
	end)
	if not ok then
		Logger.error(LOG, "set(): failed to write key '%s' — %s", tostring(key), tostring(err))
		return false
	end
	return true
end

--- Reads the value stored under the given key.
--- @param key string The settings key to read.
--- @param default_value any Returned when no value is stored for the key.
--- @return any The stored value, or default_value when the key is absent.
function M.get(key, default_value)
	local ok, result = pcall(function()
		return hs.settings.get(key)
	end)
	if not ok then
		Logger.error(LOG, "get(): failed to read key '%s' — %s", tostring(key), tostring(result))
		return default_value
	end
	if result == nil then
		return default_value
	end
	return result
end

--- Deletes the entry for the given key from the persistent store.
--- @param key string The settings key to remove.
--- @return boolean Always true; a missing key is not treated as an error.
function M.delete(key)
	local ok, err = pcall(function()
		hs.settings.clear(key)
	end)
	if not ok then
		Logger.error(LOG, "delete(): failed to clear key '%s' — %s", tostring(key), tostring(err))
	end
	-- Missing key is a non-error; callers only care that the key is gone
	return true
end

--- Reports whether a value is currently stored under the given key.
--- @param key string The settings key to probe.
--- @return boolean True if a value exists for the key, false otherwise.
function M.has(key)
	local ok, result = pcall(function()
		return hs.settings.get(key)
	end)
	if not ok then
		Logger.error(LOG, "has(): failed to probe key '%s' — %s", tostring(key), tostring(result))
		return false
	end
	return result ~= nil
end

--- Returns all keys currently present in the persistent store.
--- @return table An array of key strings, or an empty table on error.
function M.keys()
	local ok, result = pcall(function()
		return hs.settings.getKeys()
	end)
	if not ok then
		Logger.error(LOG, "keys(): failed to retrieve key list — %s", tostring(result))
		return {}
	end
	if type(result) ~= "table" then
		return {}
	end
	-- hs.settings.getKeys() returns a hash-style table; convert to an array
	local arr = {}
	for k in pairs(result) do
		arr[#arr + 1] = k
	end
	return arr
end

--- Deletes every key currently present in the persistent store.
--- @return boolean True when all entries have been removed without error.
function M.clear()
	local keys = M.keys()
	for _, k in ipairs(keys) do
		M.delete(k)
	end
	Logger.debug(LOG, "clear(): removed %d key(s).", #keys)
	return true
end

return M
