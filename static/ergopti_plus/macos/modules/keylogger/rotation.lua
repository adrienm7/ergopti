--- modules/keylogger/rotation.lua

--- ==============================================================================
--- MODULE: Keylogger Log Rotation
--- DESCRIPTION:
--- Manages the today.log hot-path file: appending JSONL events and performing
--- daily rollovers. Also owns the tail-read logic that the ingest tick uses to
--- consume new lines from today.log without re-reading already-processed bytes.
---
--- HOT PATH NOTE:
--- M.append_log() is called on every keystroke. It must never block on SQLite.
--- All it does is open today.log in append mode, write one JSON line, and close.
---
--- DAY ROLLOVER:
--- M.day_rollover() is called at midnight by the keylogger init watchdog. It
--- drains remaining today.log lines into the ingest pipeline, appends a marker
--- comment to data.sql, and resets the tail offset so tomorrow starts fresh.
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.fs, hs.timer.
--- ==============================================================================

local M = {}

local hs   = hs
local fs   = require("hs.fs")
local json = require("hs.json")

local Logger = require("lib.logger")
local LOG    = "keylogger.rotation"





-- ===============================
-- ===============================
-- ======= 1/ Module State =======
-- ===============================
-- ===============================

--- Maximum JSONL lines consumed per ingest tick.
local INGEST_BATCH_LINES = 5000

--- Shared state injected by M.init().
local _state = nil

--- Resolved path bundle injected by M.init().
local _paths = nil

--- Watermark (byte offset) of the today.log bytes already consumed by ingest.
--- Persisted to meta.today_log_offset so a crash mid-cycle does not duplicate.
local _today_log_offset = 0

--- The calendar date ("YYYY-MM-DD") to which _today_log_offset belongs.
local _today_log_date = nil

--- Whether M.init has been called.
local _initialized = false

--- Persistent append handle for today.log — opened once in M.init() and reused
--- across every M.append_log() call so the hot path never pays open()/close().
local _log_handle = nil





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

--- Report whether M.init() has already completed.
--- Callers MUST use this instead of probing for the presence of an accessor
--- function (e.g. `not Rotation.get_offset`) to infer initialisation: every
--- module function is defined at require time and is therefore truthy whether
--- or not init ran, so such a probe is a constant that silently never fires.
--- @return boolean True once M.init() has completed.
function M.is_initialized()
	return _initialized
end

--- Returns today's "YYYY-MM-DD" date string.
local function _today()
	return os.date("%Y-%m-%d")
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" timestamp string (local time).
-- Single-sourced in modules/keylogger/timestamp.lua so the seconds and the .mmm
-- fraction share one wall clock (F-L1).
local _now_ts = require("modules.keylogger.timestamp").now_ts





-- =====================================================
-- =====================================================
-- ======= 3/ Offset accessors (for log_manager) =======
-- =====================================================
-- =====================================================

--- Return the current tail-read watermark.
--- @return integer Byte offset.
function M.get_offset()
	return _today_log_offset
end

--- Return the calendar date the current offset belongs to.
--- @return string|nil "YYYY-MM-DD" or nil if not yet set.
function M.get_date()
	return _today_log_date
end

--- Persist both offset and date after a successful ingest cycle.
--- @param offset integer New byte offset past consumed lines.
--- @param date   string  The date string for the consumed lines.
function M.set_offset(offset, date)
	_today_log_offset = offset
	_today_log_date   = date
end





-- ==================================================================
-- ==================================================================
-- ======= 4/ today.log Append (hot path — no SQLite touches) =======
-- ==================================================================
-- ==================================================================

--- Append a single event entry to today.log as a JSONL line.
--- Hot path: every keystroke ends up here. Never touches SQLite.
--- @param entry table The event entry. Must contain a `type` field.
function M.append_log(entry)
	if not _require_init("append_log") then return end
	if type(entry) ~= "table" or type(entry.type) ~= "string" then
		Logger.warn(LOG, "append_log: invalid entry — skipping")
		return
	end
	entry.timestamp = entry.timestamp or _now_ts()

	local ok, str = pcall(json.encode, entry)
	if not ok then
		Logger.error(LOG, "JSON encode failed for type '%s': %s.",
			tostring(entry.type), tostring(str))
		return
	end
	-- Collapse any embedded newlines so the file stays valid JSONL
	str = str:gsub("\n", "")

	-- Reopen if the handle was lost (e.g. external rotation deleted the file).
	if not _log_handle then
		_log_handle = io.open(_paths.today_log_path, "a")
	end
	if not _log_handle then
		Logger.error(LOG, "Cannot append to today.log at %s.",
			_paths.today_log_path)
		return
	end
	_log_handle:write(str .. "\n")
	_log_handle:flush()
end





-- ==============================================
-- ==============================================
-- ======= 5/ Tail Read (for ingest tick) =======
-- ==============================================
-- ==============================================

--- Read newly appended bytes of today.log past the stored watermark and
--- return them as a list of {entry, raw} items plus the post-read offset.
--- Stops after INGEST_BATCH_LINES entries to keep each tick short.
--- @return table, integer List of parsed entries, new byte offset.
function M.read_new_entries()
	if not _require_init("read_new_entries") then return {}, _today_log_offset end

	-- The offset is only reset by M.rollover(); resetting it here would cause
	-- double-aggregation when day_rollover() calls ingest_once() at midnight
	-- (the date has already changed but the old today.log still needs draining).
	local today = _today()
	if not _today_log_date then _today_log_date = today end

	local attrs = fs.attributes(_paths.today_log_path)
	if not attrs then return {}, _today_log_offset end
	local size = attrs.size or 0
	if size <= _today_log_offset then return {}, _today_log_offset end

	local fh, err = io.open(_paths.today_log_path, "r")
	if not fh then
		Logger.warn(LOG, "Cannot open today.log %s: %s.",
			_paths.today_log_path, tostring(err))
		return {}, _today_log_offset
	end
	fh:seek("set", _today_log_offset)
	local out, lines = {}, 0
	while lines < INGEST_BATCH_LINES do
		local line = fh:read("*l")
		if not line then break end
		local ok, entry = pcall(json.decode, line)
		if ok and type(entry) == "table" and type(entry.type) == "string"
		   and type(entry.timestamp) == "string" then
			table.insert(out, { entry = entry, raw = line })
		end
		lines = lines + 1
	end
	local new_offset = fh:seek("cur")
	fh:close()
	return out, new_offset
end





-- =======================================
-- =======================================
-- ======= 6/ Day Rollover Handler =======
-- =======================================
-- =======================================

--- Perform a daily log rollover: delete today.log and reset the offset
--- so tomorrow starts fresh. The caller (log_manager) must drain the
--- remaining today.log into the ingest pipeline before calling this.
--- @param data_sql_path string Path to the append-only data.sql file.
function M.rollover(data_sql_path)
	if not _require_init("rollover") then return end

	-- Append a human-readable boundary marker to data.sql
	local prev_date = _today_log_date or ""
	local new_date  = _today()
	local f = io.open(data_sql_path, "a")
	if f then
		f:write(string.format("\n-- === day rollover %s -> %s ===\n",
			prev_date, new_date))
		f:close()
	end

	pcall(os.remove, _paths.today_log_path)
	-- Close and nil the persistent handle so the next append_log reopens
	-- against the fresh file. Without this, writes go to the old (now
	-- unlinked) inode while the new today.log is a different file.
	if _log_handle then
		_log_handle:close()
		_log_handle = nil
	end
	_today_log_offset = 0
	_today_log_date   = new_date
end





-- ==============================
-- ==============================
-- ======= 7/ Initializer =======
-- ==============================
-- ==============================

--- Initialize the rotation module with resolved paths and shared state.
--- @param deps table Must contain: paths (table), state (table).
---                   May also carry: today_log_offset (integer), today_log_date (string).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table"
		or type(deps.paths) ~= "table"
		or type(deps.state) ~= "table" then
		Logger.error(LOG, "M.init(): invalid deps — rotation module non-functional.")
		return
	end
	if _initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_paths = deps.paths
	_state = deps.state
	_today_log_offset = deps.today_log_offset or 0
	_today_log_date   = deps.today_log_date   or nil

	-- Open a persistent append handle for today.log so the hot path never
	-- pays the cost of open()/close() on every keystroke.
	_log_handle = io.open(_paths.today_log_path, "a")
	if not _log_handle then
		Logger.error(LOG, "Cannot open today.log at %s for append — log writes will fail.",
			_paths.today_log_path)
	end

	_initialized = true
	Logger.success(LOG, "Initialized (offset=%d).", _today_log_offset)
end

return M
