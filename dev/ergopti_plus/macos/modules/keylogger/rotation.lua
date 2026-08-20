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
--- It reuses one unbuffered append handle and accepts a line only after write
--- reports its documented success value.
---
--- DAY ROLLOVER:
--- M.day_rollover() is called at midnight by the keylogger init watchdog. It
--- drains remaining today.log lines into the ingest pipeline, appends a marker
--- comment to data.sql, and resets the tail offset so tomorrow starts fresh.
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json.
--- ==============================================================================

local M = {}

local json = require("hs.json")

local Logger = require("infra.logger")
local LOG    = "keylogger.rotation"





-- ===============================
-- ===============================
-- ======= 1/ Module State =======
-- ===============================
-- ===============================

--- Maximum JSONL lines consumed per ingest tick.
local INGEST_BATCH_LINES = 5000

--- Tail-read outcomes. Only READ_STATUS_EOF authorizes destructive rollover;
--- an empty entry list alone is never proof that the journal was fully read.
M.READ_STATUS_BATCH  = "batch"
M.READ_STATUS_EOF    = "eof"
M.READ_STATUS_FAILED = "failed"

--- POSIX errno returned by io.open() when today.log does not exist. In the
--- single-threaded Hammerspoon callback this is a committed empty-journal state.
local ENOENT_ERROR_CODE = 2

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

--- A failed unbuffered write may have left a partial unterminated record. The
--- next retry starts on a fresh line so that its complete JSON object remains
--- independently ingestible after storage recovers.
local _append_boundary_required = false





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

--- Invalidates an append handle after an ambiguous unbuffered write result.
--- The exact handle is closed best-effort and never reused: stdio buffer state
--- after ENOSPC is undefined, so a retry must acquire a fresh stream.
--- @param stage string Failed operation name for diagnostics.
--- @param detail any Non-sensitive failure detail returned by the file API.
--- @return boolean Always false so callers propagate the refused transaction.
local function _reject_append_handle(stage, detail)
	local failed_handle = _log_handle
	_log_handle = nil
	if failed_handle then
		local close_ok, close_result = pcall(failed_handle.close, failed_handle)
		if not close_ok or close_result ~= true then
			Logger.warn(LOG, "today.log handle close after %s failure was not confirmed.", stage)
		end
	end
	Logger.error(LOG, "Cannot append to today.log: %s failed (%s).",
		stage, tostring(detail))
	return false
end

--- Opens today.log in unbuffered append mode. With stdio buffering disabled,
--- file:write() is the only ambiguous persistence boundary: a successful return
--- means the complete line reached the OS, while nil/throw means a possibly
--- partial line must be isolated before retry. A later flush cannot add a second
--- uncertainty window because there is no userspace buffer left to flush.
--- @return boolean opened True only when a configured handle is published.
local function _open_append_handle()
	local open_ok, handle_or_err, open_detail = pcall(io.open,
		_paths.today_log_path, "a")
	if not open_ok or handle_or_err == nil then
		Logger.error(LOG, "Cannot open today.log for append (%s).",
			tostring(open_detail or handle_or_err))
		return false
	end

	local setvbuf_ok, configured_or_err, config_detail = pcall(
		handle_or_err.setvbuf, handle_or_err, "no")
	if not setvbuf_ok or configured_or_err ~= true then
		pcall(handle_or_err.close, handle_or_err)
		Logger.error(LOG, "Cannot configure unbuffered today.log append (%s).",
			tostring(config_detail or configured_or_err))
		return false
	end

	_log_handle = handle_or_err
	return true
end

--- Append a single event entry to today.log as a JSONL line.
--- Hot path: every keystroke ends up here. Never touches SQLite.
--- @param entry table The event entry. Must contain a `type` field.
--- @return boolean True only after one unbuffered write accepted the complete line.
function M.append_log(entry)
	if not _require_init("append_log") then return false end
	if type(entry) ~= "table" or type(entry.type) ~= "string" then
		Logger.warn(LOG, "append_log: invalid entry — skipping")
		return false
	end
	entry.timestamp = entry.timestamp or _now_ts()

	local ok, str = pcall(json.encode, entry)
	if not ok then
		Logger.error(LOG, "JSON encode failed for type '%s': %s.",
			tostring(entry.type), tostring(str))
		return false
	end
	-- Collapse any embedded newlines so the file stays valid JSONL
	str = str:gsub("\n", "")

	-- Reopen if the handle was lost (e.g. external rotation deleted the file).
	if not _log_handle and not _open_append_handle() then return false end

	local prefix = _append_boundary_required and "\n" or ""
	local write_ok, write_result, write_detail = pcall(_log_handle.write,
		_log_handle, prefix .. str .. "\n")
	if not write_ok or write_result == nil or write_result == false then
		_append_boundary_required = true
		return _reject_append_handle("write", write_detail or write_result)
	end

	_append_boundary_required = false
	return true
end





-- ==============================================
-- ==============================================
-- ======= 5/ Tail Read (for ingest tick) =======
-- ==============================================
-- ==============================================

--- Read newly appended bytes of today.log past the stored watermark. The third
--- result distinguishes a capped batch, committed EOF, and any I/O failure;
--- callers must never infer EOF from an empty list. Stops after
--- INGEST_BATCH_LINES entries to keep each tick short.
--- @return table entries List of parsed {entry, raw} items.
--- @return integer offset New byte offset, or the previous committed offset on failure.
--- @return string status One of READ_STATUS_BATCH, READ_STATUS_EOF, READ_STATUS_FAILED.
function M.read_new_entries()
	if not _require_init("read_new_entries") then
		return {}, _today_log_offset, M.READ_STATUS_FAILED
	end

	-- The offset is only reset by M.rollover(); resetting it here would cause
	-- double-aggregation when day_rollover() calls ingest_once() at midnight
	-- (the date has already changed but the old today.log still needs draining).
	local today = _today()
	if not _today_log_date then _today_log_date = today end

	local open_ok, fh, open_detail, open_code = pcall(io.open, _paths.today_log_path, "r")
	if not open_ok or not fh then
		if open_ok and open_code == ENOENT_ERROR_CODE then
			return {}, _today_log_offset, M.READ_STATUS_EOF
		end
		Logger.warn(LOG, "Cannot open today.log; committed offset %d preserved "
			.. "(failure content withheld; terminal type: %s).",
			_today_log_offset, type(open_detail))
		return {}, _today_log_offset, M.READ_STATUS_FAILED
	end

	local function fail_read(stage)
		pcall(fh.close, fh)
		Logger.warn(LOG, "today.log tail read failed at %s; committed offset %d preserved.",
			stage, _today_log_offset)
		return {}, _today_log_offset, M.READ_STATUS_FAILED
	end

	local size_ok, size = pcall(fh.seek, fh, "end")
	if not size_ok or type(size) ~= "number" then return fail_read("size query") end
	if size < _today_log_offset then return fail_read("offset validation") end
	if size == _today_log_offset then
		local close_ok, closed = pcall(fh.close, fh)
		if not close_ok or closed ~= true then
			Logger.warn(LOG, "today.log EOF close failed; committed offset %d preserved.",
				_today_log_offset)
			return {}, _today_log_offset, M.READ_STATUS_FAILED
		end
		return {}, _today_log_offset, M.READ_STATUS_EOF
	end

	local seek_ok, start_offset = pcall(fh.seek, fh, "set", _today_log_offset)
	if not seek_ok or start_offset ~= _today_log_offset then return fail_read("initial seek") end

	local out, lines = {}, 0
	local reached_eof = false
	while lines < INGEST_BATCH_LINES do
		local read_ok, line, read_detail, read_code = pcall(fh.read, fh, "*l")
		if not read_ok then return fail_read("line read") end
		if line == nil then
			if read_detail ~= nil or read_code ~= nil then return fail_read("line read") end
			reached_eof = true
			break
		end
		if type(line) ~= "string" then return fail_read("line type validation") end
		local ok, entry = pcall(json.decode, line)
		if ok and type(entry) == "table" and type(entry.type) == "string"
		   and type(entry.timestamp) == "string" then
			table.insert(out, { entry = entry, raw = line })
		end
		lines = lines + 1
	end

	local offset_ok, new_offset = pcall(fh.seek, fh, "cur")
	if not offset_ok or type(new_offset) ~= "number" then return fail_read("final seek") end
	if new_offset > size then return fail_read("snapshot validation") end
	if reached_eof and new_offset ~= size then return fail_read("EOF validation") end

	local close_ok, closed = pcall(fh.close, fh)
	if not close_ok or closed ~= true then
		Logger.warn(LOG, "today.log tail-read close failed; committed offset %d preserved.",
			_today_log_offset)
		return {}, _today_log_offset, M.READ_STATUS_FAILED
	end
	return out, new_offset, reached_eof and M.READ_STATUS_EOF or M.READ_STATUS_BATCH
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
--- @param read_status string Must be READ_STATUS_EOF from the immediately
--- preceding drain check.
--- @return boolean True when rollover ran, false when the EOF proof was absent.
function M.rollover(data_sql_path, read_status)
	if not _require_init("rollover") then return false end
	if read_status ~= M.READ_STATUS_EOF then
		Logger.warn(LOG, "rollover refused without a committed EOF status; today.log preserved.")
		return false
	end

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
	return true
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
	_append_boundary_required = false

	-- Open a persistent append handle for today.log so the hot path never
	-- pays the cost of open()/close() on every keystroke.
	if not _open_append_handle() then
		Logger.error(LOG, "Cannot open today.log at %s for append — log writes will fail.",
			_paths.today_log_path)
	end

	_initialized = true
	Logger.success(LOG, "Initialized (offset=%d).", _today_log_offset)
end

return M
