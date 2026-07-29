--- adapters/storage.lua

--- ==============================================================================
--- MODULE: Storage Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Storage port contract defined in
--- static/ergopti_plus/_shared/core/ports/Storage.spec.js. Provides a key-value
--- persistent store backed by a JSON file under XDG_CONFIG_HOME
--- (~/.config/ergopti_plus/storage.json) so settings survive daemon restarts
--- and reboots without depending on D-Bus or gconf.
---
--- FEATURES & RATIONALE:
--- 1. XDG-compliant path: respects XDG_CONFIG_HOME so containerised environments
---    and users with non-standard home directories work out of the box.
--- 2. Atomic write: data is written to a .tmp file then renamed so a crash during
---    a write never corrupts the main store.
--- 3. Lazy load: the JSON file is read only on the first call (or after reload),
---    keeping daemon startup fast.
--- 4. Fail-safe returns: every method returns a safe default on error.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell  = require("adapters.shell_runner")

-- Shared pure-Lua JSON codec (single source of truth for all Lua drivers). The
-- bespoke encoder/decoder this replaces silently flattened nested tables and
-- dropped arrays on the decode path, corrupting any non-flat stored value
local json = require("json")

local LOG = "adapters.storage"


-- ========================================
-- ========================================
-- ======= 1/ Path Resolution =============
-- ========================================
-- ========================================

local function _config_dir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then return xdg .. "/ergopti_plus/" end
	local home = os.getenv("HOME") or "/tmp"
	return home .. "/.config/ergopti_plus/"
end

local _STORE_PATH = _config_dir() .. "storage.json"
local _TMP_PATH   = _STORE_PATH .. ".tmp"


-- ========================================
-- ========================================
-- ======= 2/ Internal State ==============
-- ========================================
-- ========================================

local _cache = nil   -- in-memory copy of the store; nil until first load


-- ========================================
-- ========================================
-- ======= 3/ Persistence Helpers =========
-- ========================================
-- ========================================

--- Loads the store from disk into _cache.
local function _load()
	local fh = io.open(_STORE_PATH, "r")
	if not fh then _cache = {} ; return end
	local content = fh:read("*a")
	fh:close()
	-- json.decode yields nil on an empty or corrupt file; fall back to an empty
	-- store so a damaged JSON never wedges the cache into a permanent nil state
	local decoded = json.decode(content)
	_cache = (type(decoded) == "table") and decoded or {}
end

--- Persists _cache to disk atomically.
--- @return boolean
local function _flush()
	if _cache == nil then return false end
	-- Ensure the config directory exists. The path comes from XDG_CONFIG_HOME or
	-- HOME, i.e. from the environment: string.format("%q") wrapped it in DOUBLE
	-- quotes, so a home directory with a space silently created two wrong
	-- directories and one with a $ or a backtick was expanded again.
	Shell.run(string.format("mkdir -p %s 2>/dev/null", Shell.quote(_config_dir())))
	local ok, err = pcall(function()
		local fh = io.open(_TMP_PATH, "w")
		if not fh then error("cannot open tmp file") end
		fh:write(json.encode(_cache))
		fh:close()
		os.rename(_TMP_PATH, _STORE_PATH)
	end)
	if not ok then
		Logger.error(LOG, "_flush(): write failed — %s", tostring(err))
		return false
	end
	return true
end

--- Ensures the in-memory cache is populated.
local function _ensure_loaded()
	if _cache == nil then _load() end
end




-- =========================================
-- =========================================
-- ======= 4/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Stores a value under the given key in the persistent store.
--- @param key string
--- @param value any Scalar or nested table value.
--- @return boolean True on success, false on error.
function M.set(key, value)
	_ensure_loaded()
	local ok, err = pcall(function()
		_cache[tostring(key)] = value
		_flush()
	end)
	if not ok then
		Logger.error(LOG, "set(): failed to write key '%s' — %s", tostring(key), tostring(err))
		return false
	end
	return true
end

--- Reads the value stored under the given key.
--- @param key string
--- @param default_value any Returned when no value is stored.
--- @return any
function M.get(key, default_value)
	_ensure_loaded()
	local ok, result = pcall(function()
		return _cache[tostring(key)]
	end)
	if not ok then
		Logger.error(LOG, "get(): failed to read key '%s' — %s", tostring(key), tostring(result))
		return default_value
	end
	if result == nil then return default_value end
	return result
end

--- Deletes the entry for the given key from the persistent store.
--- @param key string
--- @return boolean Always true.
function M.delete(key)
	_ensure_loaded()
	pcall(function()
		_cache[tostring(key)] = nil
		_flush()
	end)
	return true
end

--- Reports whether a value is currently stored under the given key.
--- @param key string
--- @return boolean
function M.has(key)
	_ensure_loaded()
	local ok, result = pcall(function()
		return _cache[tostring(key)] ~= nil
	end)
	if not ok then
		Logger.error(LOG, "has(): failed to probe key '%s' — %s", tostring(key), tostring(result))
		return false
	end
	return result == true
end

--- Returns all keys currently present in the persistent store.
--- @return table Array of key strings.
function M.keys()
	_ensure_loaded()
	local ok, result = pcall(function()
		local arr = {}
		for k in pairs(_cache) do arr[#arr + 1] = k end
		return arr
	end)
	if not ok then
		Logger.error(LOG, "keys(): failed to retrieve key list — %s", tostring(result))
		return {}
	end
	return type(result) == "table" and result or {}
end

--- Deletes every key currently present in the persistent store.
--- @return boolean True when all entries have been removed without error.
function M.clear()
	_ensure_loaded()
	local count = 0
	for _ in pairs(_cache) do count = count + 1 end
	_cache = {}
	_flush()
	Logger.debug(LOG, "clear(): removed %d key(s).", count)
	return true
end

return M
