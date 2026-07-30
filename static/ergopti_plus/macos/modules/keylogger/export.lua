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
-- =============================================
-- ======= 1/ Module State and Constants =======
-- =============================================
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
-- ===================================
-- ======= 2/ Guards and Utils =======
-- ===================================
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
-- Single-sourced in modules/keylogger/timestamp.lua so the seconds and the .mmm
-- fraction share one wall clock (F-L1).
local _now_ts = require("modules.keylogger.timestamp").now_ts





-- =======================================
-- ======================================
-- ======= 3/ App Category Lookup =======
-- ======================================
-- =======================================

-- Per-app-name category memo. Declared above the function that reads it: a local
-- placed below would bind the nil global instead.
local _category_cache = {}

-- Memo sentinel for "this bundle was readable and declares no category". A plain
-- nil cannot express it (nil is indistinguishable from "never looked"), and the
-- localised fallback string cannot either, because the active locale can change at
-- runtime and the memo must outlive that.
local CATEGORY_NONE = "\0none"

--- Return the human-readable category for an app, looked up via macOS
--- LSApplicationCategoryType. Falls back to the i18n "general" label when
--- the app is not running or not categorized.
--- @param app_name string The application name as reported by Hammerspoon.
--- @return string Localized category string.
function M.get_native_app_category(app_name)
	if type(app_name) ~= "string" or app_name == "" then
		return i18n.get("metrics_apps.general_category")
	end
	-- Memoised per app name. Every ingest tick re-resolved each app's category
	-- with a running-application scan plus an Info.plist read from disk, and did
	-- it INSIDE the open SQLite write transaction — so the database stayed locked
	-- for the duration of a filesystem round-trip per distinct app, on a timer.
	-- An app's LSApplicationCategoryType does not change while it is installed.
	local cached = _category_cache[app_name]
	if cached == CATEGORY_NONE then
		-- Known to have no category. The label still goes through i18n on every
		-- answer so a locale change at runtime is reflected.
		return i18n.get("metrics_apps.general_category")
	end
	if cached ~= nil then return cached end

	local resolved = nil
	-- Two structurally different misses, and only one of them may be memoised.
	-- `app` nil means "not running RIGHT NOW", which is a property of this instant
	-- and not of the name.
	local app = hs.application.get(app_name)
	local bundle_was_readable = false
	if app then
		local app_path = app:path()
		if type(app_path) == "string" then
			local info = hs.application.infoForBundlePath(app_path)
			if info then
				bundle_was_readable = true
				if info.LSApplicationCategoryType then
					local raw = info.LSApplicationCategoryType:gsub("public%.app%-category%.", "")
					raw = raw:gsub("%-", " ")
					local cap = raw:sub(1, 1):upper() .. raw:sub(2)
					resolved = MAC_CATEGORIES_FR[cap] or cap
				end
			end
		end
	end

	if resolved ~= nil then
		_category_cache[app_name] = resolved
		return resolved
	end

	-- The bundle was read and simply carries no LSApplicationCategoryType. That is
	-- a property of the installed bundle, so it is learned once. The comment here
	-- used to claim every miss was cached while the code stored only the successes,
	-- which meant every uncategorised app re-ran the running-application scan AND
	-- the Info.plist read on every ingest tick — inside the open SQLite write
	-- transaction, so the database stayed locked for a filesystem round-trip each
	-- time.
	--
	-- The sentinel is deliberately NOT the localised fallback string: the active
	-- locale can change at runtime, so what is memoised is "this bundle has no
	-- category" and the label is resolved fresh on every answer.
	if bundle_was_readable then
		_category_cache[app_name] = CATEGORY_NONE
		return i18n.get("metrics_apps.general_category")
	end

	-- app was nil, or its bundle could not be read. Nothing is memoised: the
	-- recovery path replays historic ledger rows whose apps are mostly not running,
	-- so a permanent sentinel here would pin dozens of names to the general
	-- fallback for the life of the Hammerspoon process.
	return i18n.get("metrics_apps.general_category")
end





-- ====================================
-- ===================================
-- ======= 4/ Device Accessors =======
-- ===================================
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
-- ===============================================
-- ======= 5/ Foreign Device Data.sql Sync =======
-- ===============================================
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
--- Returns the byte offset (within `chunk`) of the end of the LAST complete
--- "COMMIT;" — i.e. the boundary up to which the chunk holds whole batches. 0 when
--- there is no complete batch yet (a torn cross-device copy of a mid-append file).
--- Exposed for testing (F-M3): applying past this boundary would exec an orphan
--- BEGIN and leave the connection in an open transaction.
--- @param chunk string Raw bytes read from a foreign data.sql past the watermark.
--- @return integer Offset of the last complete batch (0 if none).
function M._last_complete_batch_offset(chunk)
	chunk = chunk or ""
	local last_commit, i, n = 0, 1, #chunk
	local in_string, in_comment = false, false
	while i <= n do
		local ch = chunk:sub(i, i)
		if in_comment then
			if ch == "\n" then in_comment = false end
		elseif in_string then
			if ch == "'" then
				-- SQLite represents a literal apostrophe by doubling it.
				if chunk:sub(i + 1, i + 1) == "'" then i = i + 1
				else in_string = false end
			end
		elseif ch == "-" and chunk:sub(i + 1, i + 1) == "-" then
			in_comment = true
			i = i + 1
		elseif ch == "'" then
			in_string = true
		elseif ch == "\n" and chunk:sub(i + 1, i + 8) == "COMMIT;\n" then
			-- The marker must be a SQL statement, not user text embedded in a
			-- multi-line literal.  The lexical state above makes that distinction.
			last_commit = i + 8
			i = i + 8
		end
		i = i + 1
	end
	return last_commit
end

--- Runs from the ingest tick. Cheap when no foreign growth has occurred since
--- the last call (just one fs.attributes() check per device folder).
---@param on_applied fun(device_id:string):boolean|nil|nil Optional callback that
--- rebuilds derived rows for a successfully imported device before its watermark
--- advances. Returning false leaves the safe raw replay retryable next tick.
---@return string[] Device ids whose raw batch and derived rebuild both completed.
function M.sync_foreign_data_sql(on_applied)
	if not _require_init("sync_foreign_data_sql") then return {} end
	local db = _get_db and _get_db()
	if not db then return {} end
	local synced_devices = {}

	local md = _paths.metrics_dir
	if not md or not fs.attributes(md) then return synced_devices end
	local by_root = md .. "by_device/"
	if not fs.attributes(by_root) then return synced_devices end

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

				-- Look up the watermark for this device.  A malformed/missing
				-- device.json leaves no devices row; applying its ledger anyway would
				-- rebuild it every tick because the watermark UPDATE affects zero rows.
				local watermark, has_device_row = 0, false
				for r in db:nrows(string.format(
					"SELECT imported_data_sql_size FROM devices WHERE device_id='%s'",
					entry:gsub("'", "''"))) do
					has_device_row = true
					watermark = tonumber(r.imported_data_sql_size) or 0
				end

				local sz = sql_attrs.size or 0
				if not has_device_row then
					Logger.warn(LOG, "Foreign sync: skipping %s because device.json is invalid.", entry:sub(1, 8))
				elseif sz > watermark then
					local rfh = io.open(data_sql, "r")
					if rfh then
						rfh:seek("set", watermark)
						local chunk = rfh:read("*a")
						rfh:close()
						if chunk and #chunk > 0 then
							-- Apply ONLY through the last complete batch boundary. A
							-- cross-device sync can copy the file mid-append, so the chunk
							-- may end with an orphan "BEGIN TRANSACTION;" + inserts and NO
							-- "COMMIT;". Exec'ing that raw leaves the connection in an open
							-- transaction (which then poisons the next local ingest BEGIN
							-- with "cannot start a transaction within a transaction") and
							-- the watermark would skip the missing COMMIT forever. Find the
							-- last "COMMIT;" and defer any trailing partial batch to the next
							-- tick; advance the watermark only to that boundary (F-M3).
							local last_commit = M._last_complete_batch_offset(chunk)
							if last_commit == 0 then
								Logger.debug(LOG, "Foreign sync: no complete batch yet for %s — deferring.",
									entry:sub(1, 8))
							else
								local applicable = chunk:sub(1, last_commit)
								local applied_to = watermark + last_commit
								local ok2, err = pcall(function()
									local rc = db:exec(applicable)
									if rc ~= sqlite3.OK then
										error("foreign exec failed: " .. (db:errmsg() or "?"))
									end
								end)
							if ok2 then
								local derived_ok = true
								if type(on_applied) == "function" then
									local callback_ok, callback_result = pcall(on_applied, entry)
									derived_ok = callback_ok and callback_result ~= false
									if not derived_ok then
										Logger.warn(LOG, "Foreign sync: derived rebuild failed for %s; watermark deferred.",
											entry:sub(1, 8))
									end
								end
								if derived_ok then
									local watermark_rc = db:exec(string.format(
										"UPDATE devices SET imported_data_sql_size=%d, updated_at='%s' WHERE device_id='%s'",
										applied_to, _now_ts():gsub("'", "''"), entry:gsub("'", "''")))
									if watermark_rc == sqlite3.OK then
										table.insert(synced_devices, entry)
										Logger.debug(LOG, "Foreign sync: applied %d byte(s) from device %s.",
											applied_to - watermark, entry:sub(1, 8))
									else
										Logger.warn(LOG, "Foreign sync: cannot advance watermark for %s: %s.",
											entry:sub(1, 8), db:errmsg() or "?")
									end
								end
							else
									-- Defensively roll back any partial transaction the failed
									-- exec opened so it cannot poison the local ingest BEGIN.
									pcall(function() db:exec("ROLLBACK;") end)
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
	return synced_devices
end





-- ===============================
-- ==============================
-- ======= 6/ Initializer =======
-- ==============================
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
