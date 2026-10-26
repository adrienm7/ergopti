--- modules/keystats/export.lua

--- ==============================================================================
--- MODULE: Keystats Export Helpers
--- DESCRIPTION:
--- Provides read-only query helpers and cross-device sync logic used by the
--- dashboard and LLM bridge. Nothing in this module writes to today.log or
--- modifies aggregate tables — it is a pure read / metadata layer.
---
--- RESPONSIBILITIES:
--- 1. App category lookup via macOS LSApplicationCategoryType.
--- 2. Device short-id helper for UI display labels.
--- 3. SQLite path and db-revision accessors used as UI cache-invalidation keys.
--- 4. Foreign-device data.sql sync: verifies durable source-prefix receipts from
---    sibling device folders before applying their committed bytes, so source
---    rewrites and compaction cannot strand cross-device metrics.
---
--- DEPENDENCIES:
--- - infra.logger, infra.i18n, infra.fs_dir (project-wide).
--- - adapters.running_application for the running-application lookup.
--- - hs.application (bundle info), hs.sqlite3, hs.json, hs.fs.
--- ==============================================================================

local M = {}

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")

local Logger = require("infra.logger")
local Queries = require("keystats.queries")
local i18n   = require("infra.i18n")
local FsDir  = require("infra.fs_dir")
local RunningApplication = require("adapters.running_application")
local ForeignLedgerSnapshot = require("adapters.foreign_ledger_snapshot")
local LOG    = "keystats.export"





-- =============================================
-- =============================================
-- ======= 1/ Module State and Constants =======
-- =============================================
-- =============================================

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

--- Bounded verification readers retained across ingest turns by exact source path.
local _foreign_readers = {}





-- ===================================
-- ===================================
-- ======= 2/ Guards and Utils =======
-- ===================================
-- ===================================

--- Guards public functions against being called before M.init().
local function _require_init(func_name)
	if not _initialized then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" timestamp string (local time).
-- Single-sourced in modules/keystats/timestamp.lua so the seconds and the .mmm
-- fraction share one wall clock (F-L1).
local _now_ts = require("modules.keystats.timestamp").now_ts





-- ======================================
-- ======================================
-- ======= 3/ App Category Lookup =======
-- ======================================
-- ======================================

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
	-- and not of the name. The lookup must stay on the process list: the ingest
	-- flush asks for every application of its batch, including ones that have
	-- quit, and a name lookup that falls back to a window search read every
	-- window of every application on the main thread (13.4 s, issue #99).
	local app = RunningApplication.by_name(app_name)
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





-- ===================================
-- ===================================
-- ======= 4/ Device Accessors =======
-- ===================================
-- ===================================

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
	for r in db:nrows(Queries.render("meta.rev", "native")) do
		return tonumber(r.value) or 0
	end
	return 0
end





-- ===============================================
-- ===============================================
-- ======= 5/ Foreign Device Data.sql Sync =======
-- ===============================================
-- ===============================================

--- Scan `metrics/by_device/*` and apply any data.sql bytes that the local
--- db.sqlite has not yet ingested. KEYSTATS_SPEC §16.
---
--- For each foreign device folder:
---  1. Reads the device's committed byte offset and exact prefix SHA-256.
---  2. Verifies that prefix in cooperative slices through one owned reader.
---  3. Applies a proved append, or replays the complete replacement generation.
---  4. Publishes offset and digest together after the derived rebuild commits.
---
--- Locate the one canonical typing tuple without interpreting arbitrary values.
--- Mac/Windows writers and the standalone compactor retain device_id,id first.
local function _typing_values_start(line)
	local upper = line:upper()
	if not upper:match("^%s*INSERT%s") then return nil, false end
	local target = upper:match("^%s*INSERT.-%s+INTO%s+([^%s%(]+)")
	if not target then return nil, true end
	local normalized = target:gsub("[`\"%[%]]", "")
	if normalized ~= "EVENTS_TYPING" and not normalized:match("%.EVENTS_TYPING$") then return nil, false end
	local verb, columns, opening = upper:match(
		"^%s*(INSERT.-)%s+INTO%s+EVENTS_TYPING%s*%((.-)%)%s*VALUES%s*()%(")
	if not verb then return nil, true end
	verb = verb:gsub("%s+", " ")
	if verb ~= "INSERT" and verb ~= "INSERT OR IGNORE" and verb ~= "INSERT OR REPLACE" then return nil, true end
	if not columns:match("^%s*DEVICE_ID%s*,%s*ID%s*,") then return nil, true end
	return opening, false
end

--- Read only the known first device literal and numeric id of one tuple.
local function _typing_tuple_id(chunk, opening, device_sql)
	local at = opening + 1
	while chunk:sub(at, at):match("%s") do at = at + 1 end
	if chunk:sub(at, at + #device_sql - 1) ~= device_sql then return nil end
	at = at + #device_sql
	while chunk:sub(at, at):match("%s") do at = at + 1 end
	if chunk:sub(at, at) ~= "," then return nil end
	at = at + 1
	while chunk:sub(at, at):match("%s") do at = at + 1 end
	local first = at
	while chunk:sub(at, at):match("%d") do at = at + 1 end
	local id = tonumber(chunk:sub(first, at - 1))
	while chunk:sub(at, at):match("%s") do at = at + 1 end
	if math.type(id) ~= "integer" or id < 0 or chunk:sub(at, at) ~= "," then return nil end
	return id
end

--- One lexical owner for complete SQL boundaries and optional rollover facts.
--- Unknown producer forms cannot authorize resets; markerless continuity remains.
local function _scan_ledger(chunk, device_sql, collect_ids, is_rollover)
	chunk = chunk or ""
	local last_commit, i, n, line_start = 0, 1, #chunk, 1
	local in_string, in_comment, in_batch = false, false, false
	local in_block = false
	local max_id, committed_max, invalid_at, lower_id = nil, nil, nil, nil
	local values_at, depth, tuple_seen = nil, 0, false
	local markers, ids = {}, {}
	while i <= n do
		local ch = chunk:sub(i, i)
		local blocked = in_block
		if device_sql and not in_string and not in_comment then
			if in_block then
				if ch == "*" and chunk:sub(i + 1, i + 1) == "/" then in_block = false; i = i + 1 end
			elseif ch == "/" and chunk:sub(i + 1, i + 1) == "*" then
				-- Unsupported block contents cannot hide a later real producer marker.
				in_block, blocked, invalid_at = true, true, invalid_at or i
			end
		end
		if not blocked and device_sql and not in_string and not in_comment then
			if i == line_start then
				local ending = chunk:find("\n", i, true) or (n + 1)
				local line = chunk:sub(i, ending - 1)
				if line:upper():match("^%s*BEGIN[%s;]") then in_batch = true end
				if not in_batch and is_rollover(line) then
					markers[#markers + 1] = { at = i, id = max_id }
					lower_id = max_id
				end
				local opening, unknown = _typing_values_start(line)
				if unknown then invalid_at = invalid_at or i end
				if opening then values_at, depth, tuple_seen = i + opening - 1, 0, false end
			end
			if values_at and i >= values_at then
				if ch == "(" then
					if depth == 0 then
						local id = not tuple_seen and _typing_tuple_id(chunk, i, device_sql) or nil
						if id == nil or (lower_id and id <= lower_id) then invalid_at = invalid_at or i
						else
							max_id = math.max(max_id or id, id)
							if collect_ids then ids[#ids + 1] = { at = i, id = id } end
						end
						tuple_seen = true
					end
					depth = depth + 1
				elseif ch == ")" then depth = depth - 1
				elseif ch == ";" then values_at = nil end
			end
		end
		if blocked then
			-- Fact scans skip block tokens; the public legacy offset scan is unchanged.
		elseif in_comment then
			if ch == "\n" then in_comment = false end
		elseif in_string then
			if ch == "'" then
				if chunk:sub(i + 1, i + 1) == "'" then i = i + 1
				else in_string = false end
			end
		elseif ch == "-" and chunk:sub(i + 1, i + 1) == "-" then
			in_comment = true
			i = i + 1
		elseif ch == "'" then in_string = true
		elseif ch == "\n" and chunk:sub(i + 1, i + 8) == "COMMIT;\n" then
			-- Keep the legacy byte-offset contract: only an outside-literal COMMIT.
			last_commit, committed_max, in_batch = i + 8, max_id, false
			i = i + 8
			line_start = i + 1
		end
		if ch == "\n" then line_start = i + 1 end
		i = i + 1
	end
	if not device_sql then return last_commit end
	local trailing = is_rollover(chunk:sub(last_commit + 1))
	local facts = { cutoffs = {}, ids = {}, max_id = committed_max, has_markers = false,
		unreadable = invalid_at ~= nil and invalid_at <= last_commit }
	for _, marker in ipairs(markers) do
		if marker.at <= last_commit or trailing then
			facts.has_markers = true
			if marker.id ~= nil and facts.cutoffs[#facts.cutoffs] ~= marker.id then
				facts.cutoffs[#facts.cutoffs + 1] = marker.id
			end
		end
	end
	for _, item in ipairs(ids) do
		if item.at <= last_commit then facts.ids[item.id] = true end
	end
	return last_commit, facts
end

--- Return the legacy last complete LF-terminated COMMIT byte offset.
---@param chunk string
---@return integer
function M._last_complete_batch_offset(chunk)
	local offset = _scan_ledger(chunk)
	return offset
end

--- Read authoritative per-device typing cutoffs from uncompacted producer SQL.
--- Multi-tuple/unknown INSERT forms are refused when marker facts are required.
---@param chunk string
---@param device_sql string SQL-escaped device literal from the canonical writer.
---@param collect_ids boolean|nil Collect ids only for the bounded local outbox.
---@param is_rollover function Strict canonical suffix predicate owned by LogManager.
---@return table|nil facts
---@return string|nil error_message
function M._typing_rollover_boundaries(chunk, device_sql, collect_ids, is_rollover)
	assert(type(is_rollover) == "function", "canonical rollover predicate required")
	local _, facts = _scan_ledger(chunk, device_sql, collect_ids, is_rollover)
	if facts.has_markers and facts.unreadable then
		return nil, "unsupported or ambiguous typing SQL at a rollover boundary"
	end
	return facts
end

--- Verify one source generation between ingest turns before admitting its SQL.
--- A durable prefix receipt is the only authority for retaining an old offset.
--- @param path string Foreign ledger path.
--- @param watermark integer Committed byte offset.
--- @param digest string|nil Digest of exactly the previously committed prefix.
--- @param size integer Captured source EOF.
--- @return table|nil receipt Verified SQL and new prefix receipt, or nil while deferred.
local function _read_foreign_sql_tail(path, watermark, digest, size)
	local reader = _foreign_readers[path]
	if reader and (reader.failed or reader.expected_offset ~= watermark or reader.expected_digest ~= digest) then
		if not ForeignLedgerSnapshot.close(reader) then return nil end
		_foreign_readers[path] = nil
		reader = nil
	end
	if not reader then
		local failure
		reader, failure = ForeignLedgerSnapshot.open(path, size, watermark, digest)
		if reader then _foreign_readers[path] = reader end
		if failure then
			if reader then reader.failed = true end
			Logger.warn(LOG, "Foreign sync: ledger %s failed; watermark preserved.", failure)
			return nil
		end
		if not ForeignLedgerSnapshot.start(reader) then
			reader.failed = true
			Logger.warn(LOG, "Foreign sync: verification scheduling failed; watermark preserved.")
			return nil
		end
	end
	local status, receipt = ForeignLedgerSnapshot.poll(reader)
	if status == "pending" then return nil end
	if not reader.handle and not reader.job then _foreign_readers[path] = nil end
	if status == "failed" then
		reader.failed = true
		Logger.warn(LOG, "Foreign sync: ledger %s failed; watermark preserved.", receipt)
		return nil
	end
	return receipt
end

--- Retire source capabilities missing from the current enumeration snapshot.
--- @param eligible table Set of source paths still admitted by this ingest.
--- @return boolean complete True only when every retired reader settled.
local function _retire_foreign_readers(eligible)
	local complete = true
	for path, reader in pairs(_foreign_readers) do
		if not eligible[path] then
			if ForeignLedgerSnapshot.close(reader) then _foreign_readers[path] = nil
			else complete = false end
		end
	end
	return complete
end

--- Close verification jobs and streams before exit, reload, or feature stop.
--- @return boolean complete True only when every owned source capability settled.
function M.cleanup()
	return _retire_foreign_readers({})
end

--- Schedule foreign verification and apply completed receipts during ingest.
--- Even equal-size files require byte continuity proof because a compaction or
--- source replacement can invalidate an offset without changing its file size.
---@param on_applied fun(device_id:string):boolean|nil|nil Optional callback that
--- rebuilds derived rows for a successfully imported device before its watermark
--- advances. Returning false leaves the safe raw replay retryable next tick.
---@return string[]|nil Device ids whose raw batch and derived rebuild both completed.
---@return string|nil error_message Enumeration failure detail.
function M.sync_foreign_data_sql(on_applied)
	if not _require_init("sync_foreign_data_sql") then return {} end
	local db = _get_db and _get_db()
	if not db then
		if not M.cleanup() then return nil, "foreign verification reader cleanup refused" end
		return {}
	end
	local synced_devices = {}
	local eligible = {}

	local md = _paths.metrics_dir
	if not md or not fs.attributes(md) then
		if not M.cleanup() then return nil, "foreign verification reader cleanup refused" end
		return synced_devices
	end
	local by_root = md .. "by_device/"
	if not fs.attributes(by_root) then
		if not M.cleanup() then return nil, "foreign verification reader cleanup refused" end
		return synced_devices
	end
	local entries, listed, list_err = FsDir.try_entries(by_root)
	if listed ~= true then
		M.cleanup()
		return nil, string.format("cannot enumerate '%s': %s", by_root, tostring(list_err))
	end

	for _, entry in ipairs(entries) do
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
				local watermark, digest, has_device_row = 0, nil, false
				for r in db:nrows(string.format(
					"SELECT imported_data_sql_size, imported_data_sql_sha256 FROM devices WHERE device_id='%s'",
					entry:gsub("'", "''"))) do
					has_device_row = true
					watermark = tonumber(r.imported_data_sql_size)
					digest = r.imported_data_sql_sha256
				end

				local sz = sql_attrs.size or 0
				if not has_device_row then
					Logger.warn(LOG, "Foreign sync: skipping invalid device.json.")
				elseif not watermark or watermark < 0 or watermark >= math.huge or watermark % 1 ~= 0 then
					Logger.warn(LOG, "Foreign sync: invalid committed source offset; import refused.")
				elseif sz > 0 then
					eligible[data_sql] = true
					local receipt = _read_foreign_sql_tail(data_sql, watermark, digest, sz)
					local chunk = receipt and receipt.chunk
					if receipt and receipt.uncommitted then
						Logger.debug(LOG, "Foreign sync: no complete batch yet — deferring.")
					end
					if chunk and #chunk > 0 then
						if watermark > 0 and receipt.offset == 0 then
							Logger.info(LOG, "Foreign sync: prior source prefix is unproved; replaying committed batches.")
						end
						watermark = receipt.offset
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
						if last_commit ~= #chunk or watermark + last_commit ~= receipt.applied_to then
							Logger.warn(LOG, "Foreign sync: verified batch boundary changed; watermark preserved.")
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
									Logger.warn(LOG, "Foreign sync: derived rebuild failed; watermark deferred.")
								end
							end
							if derived_ok then
								local watermark_rc = db:exec(string.format(
									"UPDATE devices SET imported_data_sql_size=%d, imported_data_sql_sha256='%s', updated_at='%s' WHERE device_id='%s'",
									applied_to, receipt.digest, _now_ts():gsub("'", "''"), entry:gsub("'", "''")))
								if watermark_rc == sqlite3.OK then
									table.insert(synced_devices, entry)
									Logger.debug(LOG, "Foreign sync: applied %d byte(s).", applied_to - watermark)
								else
									Logger.warn(LOG, "Foreign sync: cannot advance watermark: %s.", db:errmsg() or "?")
								end
							end
						else
								-- Defensively roll back any partial transaction the failed
								-- exec opened so it cannot poison the local ingest BEGIN.
								pcall(function() db:exec("ROLLBACK;") end)
								Logger.warn(LOG, "Foreign sync rolled back: %s.", tostring(err))
							end
						end
					end
				end
			end
		end
	end
	if not _retire_foreign_readers(eligible) then
		return nil, "foreign verification reader cleanup refused"
	end
	return synced_devices
end





-- ==============================
-- ==============================
-- ======= 6/ Initializer =======
-- ==============================
-- ==============================

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
