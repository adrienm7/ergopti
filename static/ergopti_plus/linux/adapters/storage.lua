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
	-- NOTE the directory is "ergopti_plus", not "ergopti" as everywhere else.
	-- Preserved deliberately: this is where existing installs keep their
	-- storage.json, and unifying the name would orphan every stored setting
	-- with no migration. The HOME fallback is the shared one.
	local ConfigPaths = require("infra.config_paths")
	return ConfigPaths.config_home() .. "/ergopti_plus/"
end

local _STORE_PATH = _config_dir() .. "storage.json"
local _TMP_PATH   = _STORE_PATH .. ".tmp"
local _CORRUPT_PATH = _STORE_PATH .. ".corrupt"


-- ========================================
-- ========================================
-- ======= 2/ Internal State ==============
-- ========================================
-- ========================================

local _cache = nil   -- in-memory copy of the store; nil until first load
local _load_blocked = false
local _recovery = nil


-- ========================================
-- ========================================
-- ======= 3/ Persistence Helpers =========
-- ========================================
-- ========================================

--- Closes a file and normalises Lua's protected-call return shape.
--- @param fh file*
--- @return boolean
local function _close(fh)
	local ok, closed = pcall(fh.close, fh)
	return ok and closed == true
end

--- Finds a recovery path without overwriting an older corrupt-store backup.
--- @return string
local function _next_recovery_path()
	local candidate = _CORRUPT_PATH
	local suffix = 0
	while true do
		local fh = io.open(candidate, "r")
		if not fh then return candidate end
		_close(fh)
		suffix = suffix + 1
		candidate = _CORRUPT_PATH .. "." .. suffix
	end
end

--- Preserves malformed store bytes before a new empty store may be created.
--- @param reason string Stable recovery reason.
local function _preserve_corrupt_store(reason)
	local recovery_path = _next_recovery_path()
	local ok, renamed = pcall(os.rename, _STORE_PATH, recovery_path)
	if ok and renamed == true then
		_recovery = { reason = reason, path = recovery_path, preserved = true }
		Logger.error(LOG, "Corrupt storage preserved at '%s'; starting with an empty store.", recovery_path)
		return
	end
	_recovery = { reason = reason, path = _STORE_PATH, preserved = false }
	_load_blocked = true
	Logger.error(LOG, "Corrupt storage could not be preserved; mutations are blocked.")
end

--- Loads the store from disk into _cache.
local function _load()
	local ok_open, fh = pcall(io.open, _STORE_PATH, "r")
	if not ok_open then
		_cache = {}
		_load_blocked = true
		Logger.error(LOG, "Storage read could not start; mutations are blocked.")
		return
	end
	if not fh then _cache = {} ; return end
	local read_ok, content = pcall(fh.read, fh, "*a")
	local close_ok = _close(fh)
	if not read_ok or type(content) ~= "string" or not close_ok then
		_cache = {}
		_load_blocked = true
		_recovery = { reason = "read_failed", path = _STORE_PATH, preserved = true }
		Logger.error(LOG, "Storage read did not commit; original file retained and mutations blocked.")
		return
	end
	local decode_ok, decoded = pcall(json.decode, content)
	if decode_ok and type(decoded) == "table" then
		_cache = decoded
		return
	end
	_cache = {}
	_preserve_corrupt_store("invalid_json")
end

--- Persists a staged cache to disk atomically.
--- @param staged table Candidate store that is not yet published in memory.
--- @return boolean
local function _flush(staged)
	if type(staged) ~= "table" or _load_blocked then return false end
	local encode_ok, payload = pcall(json.encode, staged)
	if not encode_ok or type(payload) ~= "string" then
		Logger.error(LOG, "_flush(): store could not be encoded.")
		return false
	end
	local open_ok, fh = pcall(io.open, _TMP_PATH, "w")
	if not open_ok or not fh then
		-- Create the directory only after a direct open proved it is needed. This
		-- keeps an already-existing directory independent of shell flavour while
		-- still requiring mkdir's exact result on a first write. The path comes
		-- from the environment and is quoted as one inert POSIX word.
		if not Shell.run(string.format("mkdir -p %s 2>/dev/null", Shell.quote(_config_dir()))) then
			Logger.error(LOG, "_flush(): configuration directory could not be created.")
			return false
		end
		open_ok, fh = pcall(io.open, _TMP_PATH, "w")
	end
	if not open_ok or not fh then
		Logger.error(LOG, "_flush(): temporary file could not be opened.")
		return false
	end
	local write_ok, written = pcall(fh.write, fh, payload)
	if not write_ok or written == nil or written == false then
		_close(fh)
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): temporary write did not commit.")
		return false
	end
	if not _close(fh) then
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): temporary file could not be closed.")
		return false
	end
	local rename_ok, renamed = pcall(os.rename, _TMP_PATH, _STORE_PATH)
	if not rename_ok or renamed ~= true then
		pcall(os.remove, _TMP_PATH)
		Logger.error(LOG, "_flush(): atomic rename failed.")
		return false
	end
	return true
end

--- Ensures the in-memory cache is populated.
local function _ensure_loaded()
	if _cache == nil then _load() end
end

--- Returns a shallow store copy suitable for top-level key transactions.
--- @return table
local function _staged_cache()
	local staged = {}
	for key, value in pairs(_cache) do staged[key] = value end
	return staged
end

--- Commits one cache mutation and publishes it only after durable persistence.
--- @param mutate function Receives the staged table.
--- @return boolean
local function _commit(mutate)
	_ensure_loaded()
	if _load_blocked then return false end
	local staged = _staged_cache()
	local ok, err = pcall(mutate, staged)
	if not ok then
		Logger.error(LOG, "Storage mutation staging failed — %s", tostring(err))
		return false
	end
	if not _flush(staged) then return false end
	_cache = staged
	return true
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
	return _commit(function(staged) staged[tostring(key)] = value end)
end

--- Stores several top-level values in one durable rename transaction.
--- @param values table Map of storage keys to values.
--- @return boolean
function M.set_many(values)
	if type(values) ~= "table" then return false end
	return _commit(function(staged)
		for key, value in pairs(values) do staged[tostring(key)] = value end
	end)
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
--- @return boolean True on success, including an already-absent key.
function M.delete(key)
	_ensure_loaded()
	if _load_blocked then return false end
	local storage_key = tostring(key)
	if _cache[storage_key] == nil then return true end
	return _commit(function(staged) staged[storage_key] = nil end)
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
	if _load_blocked then return false end
	local count = 0
	for _ in pairs(_cache) do count = count + 1 end
	if count == 0 then return true end
	if not _commit(function(staged)
		for key in pairs(staged) do staged[key] = nil end
	end) then
		return false
	end
	Logger.debug(LOG, "clear(): removed %d key(s).", count)
	return true
end

--- Returns recovery metadata after a corrupt or incomplete store read.
--- @return table|nil { reason, path, preserved }
function M.recovery_status()
	if not _recovery then return nil end
	return {
		reason = _recovery.reason,
		path = _recovery.path,
		preserved = _recovery.preserved,
	}
end

return M
