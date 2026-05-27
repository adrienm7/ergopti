--- modules/keylogger/export.lua

--- ==============================================================================
--- MODULE: Keylogger Export Helpers
--- DESCRIPTION:
--- Provides read-only query helpers and cross-device sync logic used by the
--- dashboard and LLM bridge. Nothing in this module writes to today.log or
--- modifies aggregate tables — it is a pure read / metadata layer.
---
--- RESPONSIBILITIES:
--- 1. App category lookup via macOS LSApplicationCategoryType.
--- 2. Device short-id helper for UI display labels.
--- 3. SQLite path and db-revision accessors used as UI cache-invalidation keys.
--- 4. Foreign-device data.sql sync: reads bytes past the stored watermark from
---    each sibling device folder and applies them to the local db.sqlite so
---    cross-device SUM queries reflect all devices.
---
--- DEPENDENCIES:
--- - lib.logger, lib.i18n (project-wide).
--- - hs.application, hs.sqlite3, hs.json, hs.fs.
--- ==============================================================================

local M = {}

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")

local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local LOG    = "keylogger.export"




-- ==============================================
--- =============================================
-- ======= 1/ Module State and Constants =======
--- =============================================
-- ==============================================

--- macOS app category → i18n key mapping.
--- MUST stay in sync with MAC_CATEGORIES_FR in log_manager if that table is
--- ever split; currently this is the single source of truth.
local MAC_CATEGORIES_FR = {
	["Productivity"]      = i18n.get("app_category.productivity"),
	["Social networking"] = i18n.get("app_category.social"),
	["Games"]             = i18n.get("app_category.games"),
	["Entertainment"]     = i18n.get("app_category.entertainment"),
	["Utilities"]         = i18n.get("app_category.utility"),
	["Education"]         = i18n.get("app_category.education"),
	["Finance"]           = i18n.get("app_category.finance"),
	["Business"]          = i18n.get("app_category.business"),
	["Graphics design"]   = i18n.get("app_category.graphics_design"),
	["Photography"]       = i18n.get("app_category.photography"),
	["Video"]             = i18n.get("app_category.video"),
	["Music"]             = i18n.get("app_category.music"),
	["Medical"]           = i18n.get("app_category.medical"),
	["Health fitness"]    = i18n.get("app_category.health"),
	["Lifestyle"]         = i18n.get("app_category.lifestyle"),
	["News"]              = i18n.get("app_category.news"),
	["Weather"]           = i18n.get("app_category.weather"),
	["Sports"]            = i18n.get("app_category.sports"),
	["Travel"]            = i18n.get("app_category.travel"),
	["Navigation"]        = i18n.get("app_category.navigation"),
	["Reference"]         = i18n.get("app_category.reference"),
	["Developer tools"]   = i18n.get("app_category.development"),
}

--- Resolved path bundle injected by M.init().
local _paths = nil

--- Device id injected by M.init().
local _device_id = nil

--- Raw sqlite3 handle injected by M.init() (read from sqlite_writer.get_db).
local _get_db = nil

--- Whether M.init has been called.
local _initialized = false




-- ====================================
--- ===================================
-- ======= 2/ Guards and Utils =======
--- ===================================
-- ====================================

--- Guards public functions against being called before M.init().
local function _require_init(func_name)
	if not _initialized then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" timestamp string (local time).
local function _now_ts()
	return string.format("%s.%03d",
		os.date("%Y-%m-%d %H:%M:%S"),
		math.floor(hs.timer.absoluteTime() / 1000000) % 1000)
end




-- =======================================
--- ======================================
-- ======= 3/ App Category Lookup =======
--- ======================================
-- =======================================

--- Return the human-readable category for an app, looked up via macOS
--- LSApplicationCategoryType. Falls back to the i18n "general" label when
--- the app is not running or not categorized.
--- @param app_name string The application name as reported by Hammerspoon.
--- @return string Localized category string.
function M.get_native_app_category(app_name)
	if type(app_name) ~= "string" or app_name == "" then
		return i18n.get("metrics_apps.general_category")
	end
	local app = hs.application.get(app_name)
	if app then
		local app_path = app:path()
		if type(app_path) ~= "string" then
			return i18n.get("metrics_apps.general_category")
		end
		local info = hs.application.infoForBundlePath(app_path)
		if info and info.LSApplicationCategoryType then
			local raw = info.LSApplicationCategoryType:gsub("public%.app%-category%.", "")
			raw = raw:gsub("%-", " ")
			local cap = raw:sub(1, 1):upper() .. raw:sub(2)
			return MAC_CATEGORIES_FR[cap] or cap
		end
	end
	return i18n.get("metrics_apps.general_category")
end




-- ====================================
--- ===================================
-- ======= 4/ Device Accessors =======
--- ===================================
-- ====================================

--- Returns a stable short label for the current device. Used by menu modules
--- that display device names without reading device.json directly.
--- @return string The first 8 chars of the device UUID followed by "…", or "".
function M.get_device_short_id()
	if not _device_id then return "" end
	return _device_id:sub(1, 8) .. "…"
end

--- Returns the absolute path to the SQLite cache file. UI bridge modules read
--- this path when opening their own read-only connection.
--- @return string|nil Path, or nil when the module is not initialized.
function M.get_sqlite_path()
	if not _paths then return nil end
	return _paths.sqlite_path
end

--- Returns the current value of the monotonic `meta.rev` counter. The UI uses
--- this as a cache-invalidation key: when rev advances, cached query results
--- are stale and must be refetched.
--- @return integer Revision counter (0 if DB is not open).
function M.get_db_rev()
	local db = _get_db and _get_db()
	if not db then return 0 end
	for r in db:nrows("SELECT value FROM meta WHERE key='rev'") do
		return tonumber(r.value) or 0
	end
	return 0
end




-- ================================================
--- ===============================================
-- ======= 5/ Foreign Device Data.sql Sync =======
--- ===============================================
-- ================================================

--- Scan `metrics/by_device/*` and apply any data.sql bytes that the local
--- db.sqlite has not yet ingested. KEYLOGGER_SPEC §16.
---
--- For each foreign device folder:
---  1. Reads `devices.imported_data_sql_size` (watermark; defaults to 0).
---  2. Reads everything from data.sql past that watermark.
---  3. Applies it inside a transaction (INSERT OR IGNORE — replay is safe).
---  4. Bumps the watermark in the `devices` row.
---
--- Runs from the ingest tick. Cheap when no foreign growth has occurred since
--- the last call (just one fs.attributes() check per device folder).
function M.sync_foreign_data_sql()
	if not _require_init("sync_foreign_data_sql") then return end
	local db = _get_db and _get_db()
	if not db then return end

	local md = _paths.metrics_dir
	if not md or not fs.attributes(md) then return end
	local by_root = md .. "by_device/"
	if not fs.attributes(by_root) then return end

	for entry in fs.dir(by_root) do
		if entry ~= "." and entry ~= ".." and entry ~= _device_id then
			local folder    = by_root .. entry .. "/"
			local djpath    = folder .. "device.json"
			local data_sql  = folder .. "data.sql"
			local djattrs   = fs.attributes(djpath)
			local sql_attrs = fs.attributes(data_sql)
			if djattrs and sql_attrs then
				-- Ensure a devices row exists so imported_data_sql_size has a home
				local fh = io.open(djpath, "r")
				if fh then
					local raw = fh:read("*a"); fh:close()
					local ok, obj = pcall(json.decode, raw)
					if ok and type(obj) == "table"
						and type(obj.device_id) == "string"
						and obj.device_id == entry then
						local stmt = db:prepare(
							"INSERT OR IGNORE INTO devices "
							.. "(device_id, name, os, os_version, host_signature, created_at, updated_at) "
							.. "VALUES (?, ?, ?, ?, ?, ?, ?)")
						if stmt then
							stmt:bind_values(obj.device_id, obj.name or "?",
								obj.os or "?", obj.os_version or "",
								obj.host_signature or "", obj.created_at or _now_ts(),
								_now_ts())
							stmt:step(); stmt:finalize()
						end
					end
				end

				-- Look up the watermark for this device
				local watermark = 0
				for r in db:nrows(string.format(
					"SELECT imported_data_sql_size FROM devices WHERE device_id='%s'",
					entry:gsub("'", "''"))) do
					watermark = tonumber(r.imported_data_sql_size) or 0
				end

				local sz = sql_attrs.size or 0
				if sz > watermark then
					local rfh = io.open(data_sql, "r")
					if rfh then
						rfh:seek("set", watermark)
						local chunk = rfh:read("*a")
						rfh:close()
						if chunk and #chunk > 0 then
							local ok2, err = pcall(function()
								local rc = db:exec(chunk)
								if rc ~= sqlite3.OK then
									error("foreign exec failed: " .. (db:errmsg() or "?"))
								end
							end)
							if ok2 then
								db:exec(string.format(
									"UPDATE devices SET imported_data_sql_size=%d, updated_at='%s' WHERE device_id='%s'",
									sz, _now_ts():gsub("'", "''"), entry:gsub("'", "''")))
								Logger.debug(LOG, "Foreign sync: applied %d byte(s) from device %s.",
									sz - watermark, entry:sub(1, 8))
							else
								Logger.warn(LOG, "Foreign sync rolled back for %s: %s.",
									entry:sub(1, 8), tostring(err))
							end
						end
					end
				end
			end
		end
	end
end




-- ===============================
--- ==============================
-- ======= 6/ Initializer =======
--- ==============================
-- ===============================

--- Initialize the export module with resolved paths and live db accessor.
--- @param deps table Must contain: paths (table), device_id (string), get_db (function).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table"
		or type(deps.paths)     ~= "table"
		or type(deps.device_id) ~= "string"
		or type(deps.get_db)    ~= "function" then
		Logger.error(LOG, "M.init(): invalid deps — export module non-functional.")
		return
	end
	if _initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_paths     = deps.paths
	_device_id = deps.device_id
	_get_db    = deps.get_db
	_initialized = true
	Logger.success(LOG, "Initialized.")
end

return M
