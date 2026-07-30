--- modules/keylogger/sqlite_writer.lua

--- ==============================================================================
--- MODULE: Keylogger SQLite Writer (Linux)
--- DESCRIPTION:
--- Encapsulates SQLite interactions for the Linux keylogger persistence layer.
--- Uses the `sqlite3` CLI binary (available on every Linux distro) via io.popen
--- — zero C-library vendoring required. Bootstraps the canonical schema from
--- _shared/data/db/schema.sql and provides INSERT helpers for the core event
--- and aggregate tables consumed by the shared metrics dashboard.
---
--- This module is the Linux counterpart to macOS's modules/keylogger/sqlite_writer.lua
--- (which uses hs.sqlite3). Both write to the same canonical schema so the
--- dashboard and cross-device sync work identically.
---
--- FEATURES & RATIONALE:
--- 1. CLI-based: every SQL statement is executed through `sqlite3 <db> "<sql>"`
---    so the daemon never links against a C library at runtime.  Slow for
---    per-keystroke writes, but flush() batches an entire session at once.
--- 2. Schema bootstrap: on first open, runs schema.sql through sqlite3 to
---    create all tables and initial meta rows.
--- 3. Minimal surface: only the tables that the Linux daemon populates are
---    wired (events_typing, ngram_chars, ngram_scancodes, agg_app_day, devices,
---    meta). Character rows carry a source histogram so generated output stays
---    distinguishable from physical typing.
---    Additional tables (bursts, sessions, ergo, etc.) live in the schema but
---    are not populated until the keylogger-walker state machine is
---    wired on Linux.
--- 4. Graceful degradation: when the sqlite3 binary is absent, writer.is_available()
---    returns false and all write methods are silent no-ops — the daemon falls
---    back to JSON export.
--- ==============================================================================

local M = {}

local Logger        = require("logger.shim")
local SqliteCommand = require("modules.keylogger.sqlite_command")

local LOG = "modules.keylogger.sqlite_writer"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Path to the SQLite database file.
local _db_path = nil

-- Whether sqlite3 CLI is available on this system.
local _available = nil

-- Whether the schema has been bootstrapped for the current db_path.
local _bootstrapped = false

-- Monotonic per-device event IDs. Stored in meta so a daemon restart cannot
-- reuse an ID and silently overwrite a previously persisted raw event.
local _next_event_id = nil


-- =========================================
-- =========================================
-- ======= 2/ Internal Helpers =============
-- =========================================
-- =========================================

--- Checks once whether the sqlite3 CLI binary is available.
--- @return boolean
local function _check_sqlite3()
	if _available ~= nil then return _available end
	local ok = os.execute("which sqlite3 >/dev/null 2>&1")
	_available = (ok == true or ok == 0)
	if not _available then
		Logger.warn(LOG, "sqlite3 CLI not found — SQLite persistence disabled.")
		Logger.warn(LOG, "  Install: sudo apt-get install sqlite3")
	end
	return _available
end

--- Escapes a string value for safe use inside a single-quoted SQL literal.
--- Replaces single quotes with '' (the SQLite escape sequence).
--- @param s string
--- @return string
local function _sql_escape(s)
	if type(s) ~= "string" then return "" end
	return s:gsub("'", "''")
end

--- Runs a SQL statement against the database via the sqlite3 CLI.
--- @param sql string Complete SQL statement(s) to execute.
--- @return boolean True on success.
local function _exec(sql)
	if not _db_path or not _available then return false end

	-- The script carries the characters the user typed, so it travels on stdin.
	-- Staging it in /tmp is what turned this module into a keystroke leak.
	local cmd, reason = SqliteCommand.build(_db_path, sql, { capture_stderr = true })
	if not cmd then
		Logger.error(LOG, "Cannot compose the sqlite3 command: %s.", reason)
		return false
	end

	local pipe = io.popen(cmd, "r")
	if not pipe then
		Logger.error(LOG, "Cannot spawn the sqlite3 CLI.")
		return false
	end
	local err_out = pipe:read("*a") or ""
	pipe:close()

	if err_out ~= "" then
		-- These statements select nothing, and stderr is merged into stdout, so
		-- any output at all means the script failed.
		Logger.error(LOG, "SQLite error: %s", SqliteCommand.sanitise_error(err_out))
		return false
	end
	return true
end

--- Runs a scalar SELECT through the sqlite3 CLI.
--- @param sql string Complete SELECT statement.
--- @return string|nil First output line, or nil when the query fails.
local function _query_scalar(sql)
	if not _db_path or not _available then return nil end
	local cmd = SqliteCommand.build(_db_path, sql, { flags = { "-noheader" } })
	if not cmd then return nil end
	local pipe = io.popen(cmd, "r")
	if not pipe then return nil end
	local value = pipe:read("*l")
	pipe:close()
	return value
end

--- Reserves consecutive event IDs transactionally within this writer process.
--- @param count number Number of IDs required.
--- @return number|nil First reserved ID.
local function _reserve_event_ids(count)
	count = math.max(1, math.floor(tonumber(count) or 1))
	if not M.is_available() then return nil end
	if not _next_event_id then
		_exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('linux_next_event_id', '1');")
		_next_event_id = tonumber(_query_scalar("SELECT value FROM meta WHERE key = 'linux_next_event_id';")) or 1
	end
	local first = _next_event_id
	_next_event_id = first + count
	if not _exec(string.format("UPDATE meta SET value = '%d' WHERE key = 'linux_next_event_id';", _next_event_id)) then
		_next_event_id = first
		return nil
	end
	return first
end

--- Reads the canonical schema file from the _shared tree.
--- @return string|nil Schema SQL, or nil on failure.
local function _read_schema()
	-- Resolve the _shared/data/db/ path relative to the driver root.
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local driver_root = src:match("^(.*)[/\\]modules[/\\]keylogger[/\\]sqlite_writer%.lua$") or "."
	driver_root = driver_root:gsub("\\", "/")
	local schema_path = driver_root .. "/../../../_shared/data/db/schema.sql"

	local fh = io.open(schema_path, "r")
	if not fh then
		-- Try relative path (works from the daemon entry point).
		local alt = "../../_shared/data/db/schema.sql"
		fh = io.open(alt, "r")
		if not fh then
			Logger.error(LOG, "Cannot read schema.sql from %s or %s.", schema_path, alt)
			return nil
		end
	end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Upgrades databases created before Linux was accepted by devices.os.
--- The raw event tables deliberately have no foreign keys, but registration
--- must still succeed so the database remains portable across all three OSes.
local function _ensure_linux_device_schema()
	local current_sql = _query_scalar("SELECT sql FROM sqlite_master WHERE type='table' AND name='devices';") or ""
	if current_sql:find("linux", 1, true) then return true end
	return _exec([[
BEGIN;
ALTER TABLE devices RENAME TO devices_pre_linux;
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  os TEXT NOT NULL CHECK (os IN ('darwin','windows','linux')),
  os_version TEXT,
  host_signature TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  imported_data_sql_size INTEGER NOT NULL DEFAULT 0,
  imported_data_sql_sha256 TEXT
);
INSERT INTO devices (device_id,name,os,os_version,host_signature,created_at,updated_at,imported_data_sql_size,imported_data_sql_sha256)
SELECT device_id,name,os,os_version,host_signature,created_at,updated_at,imported_data_sql_size,imported_data_sql_sha256 FROM devices_pre_linux;
DROP TABLE devices_pre_linux;
COMMIT;
]])
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Returns true when the SQLite backend is available (binary found + db opened).
--- @return boolean
function M.is_available()
	return _available == true and _db_path ~= nil
end

--- Opens (or creates) the SQLite database at the given path and bootstraps the
--- canonical schema on first open.
--- @param db_path string Absolute path to the .sqlite file (e.g. ~/.local/share/ergopti/metrics.sqlite).
--- @return boolean True on success.
function M.open_db(db_path)
	if type(db_path) ~= "string" or db_path == "" then
		Logger.error(LOG, "open_db(): db_path must be a non-empty string.")
		return false
	end

	if not _check_sqlite3() then return false end

	_db_path = db_path
	_next_event_id = nil

	-- Ensure the parent directory exists.
	local dir = db_path:match("^(.*)[/\\]") or "."
	os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir:gsub("'", "'\\''")))

	-- Bootstrap schema on first open.
	if not _bootstrapped then
		local schema = _read_schema()
		if not schema then
			Logger.error(LOG, "Schema bootstrap failed — cannot open database.")
			_db_path = nil
			return false
		end

		-- Check if the DB file already exists (has a non-zero size).
		local fh = io.open(_db_path, "r")
		local existed = false
		if fh then
			existed = (fh:seek("end") or 0) > 0
			fh:close()
		end

		if not existed then
			Logger.info(LOG, "Bootstrapping schema into %s …", _db_path)
			if not _exec(schema) then
				Logger.error(LOG, "Schema execution failed.")
				_db_path = nil
				return false
			end
			Logger.success(LOG, "Schema bootstrapped successfully.")
		end

		_bootstrapped = true
	end
	if not _ensure_linux_device_schema() then
		Logger.error(LOG, "Unable to upgrade device registry for Linux support.")
		_db_path = nil
		return false
	end

	Logger.debug(LOG, "SQLite database open: %s", _db_path)
	return true
end

--- Closes the database connection (no-op for CLI-based backend, but cleans up state).
function M.close_db()
	_db_path = nil
	_bootstrapped = false
	_next_event_id = nil
	Logger.debug(LOG, "SQLite database closed.")
end

--- Returns the current database path (for diagnostics).
--- @return string|nil
function M.get_db_path()
	return _db_path
end

--- Returns the dashboard cache revision, or nil when no database is open.
function M.get_revision()
	if not M.is_available() then return nil end
	return tonumber(_query_scalar("SELECT value FROM meta WHERE key = 'rev';"))
end

--- Registers (or updates) the current device in the devices table.
--- @param device_id      string Unique device identifier (e.g. hostname).
--- @param device_name    string Human-readable device name.
--- @param os_name        string "linux".
--- @param os_version     string Kernel version or distro name.
--- @param host_signature string Host-specific fingerprint.
function M.register_device(device_id, device_name, os_name, os_version, host_signature)
	if not M.is_available() then return end

	local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local sql = string.format([[
INSERT OR REPLACE INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at)
VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s');
]],
		_sql_escape(device_id),
		_sql_escape(device_name or device_id),
		_sql_escape(os_name or "linux"),
		_sql_escape(os_version or ""),
		_sql_escape(host_signature or device_id),
		now, now
	)
	_exec(sql)
	Logger.debug(LOG, "Device '%s' registered.", device_id)
end

--- Inserts a batch of keystroke events into the events_typing table.
--- Each event is a single keystroke row.
---
--- NOTE: the full keylogger-walker processes individual keystrokes into
--- bursts, sessions, and ergo stats. Until that walker is wired on Linux, this
--- method records a single summary row per flush cycle — enough for the
--- dashboard to show daily totals and n-grams.
---
--- @param device_id  string   Device identifier.
--- @param events     table    Array of { ts, date, app, text, wpm?, layout? } event tables.
function M.insert_typing_events(device_id, events)
	if not M.is_available() then return end
	if type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end

	local parts = {}
	for i, ev in ipairs(events) do
		local ts      = _sql_escape(ev.ts      or os.date("!%Y-%m-%d %H:%M:%S"))
		local date    = _sql_escape(ev.date    or os.date("!%Y-%m-%d"))
		local app     = _sql_escape(ev.app     or "unknown")
		local text    = _sql_escape(ev.text    or "")
		local title   = _sql_escape(ev.title   or "")
		local wpm     = tonumber(ev.wpm) or 0
		local layout  = _sql_escape(ev.layout  or "")
		local events_json = _sql_escape(ev.events_json or "[]")

		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s','','',0,0,0,0,0,%d,0,0,0.0,'%s','','%s')",
			_sql_escape(device_id), first_id + i - 1, ts, date, app, title,
			wpm, text, events_json
		)
	end

	local sql = string.format(
		"INSERT OR IGNORE INTO events_typing "
		.. "(device_id,id,ts,date,app,title,url,field_role,layout,document_path,"
		.. "is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,"
		.. "pause_before_ms,battery_level,audio_volume,wpm,text,rich_text,events_json) "
		.. "VALUES %s;",
		table.concat(parts, ",")
	)
	return _exec(sql)
end

--- Inserts canonical hotstring events matching the macOS/Windows table shape.
--- @param device_id string Device identifier.
--- @param events table Array of {ts,date,app,kind,trigger,replacement,h_type,net_saved_chars}.
function M.insert_hotstring_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s','%s','%s','%s',%d)",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("!%Y-%m-%d")),
			_sql_escape(ev.app or "unknown"),
			_sql_escape(ev.kind or "fired"),
			_sql_escape(ev.trigger or ""),
			_sql_escape(ev.replacement or ""),
			_sql_escape(ev.h_type or "unknown"),
			tonumber(ev.net_saved_chars) or 0
		)
	end
	return _exec("INSERT OR IGNORE INTO events_hotstring "
		.. "(device_id,id,ts,date,app,kind,trigger,replacement,h_type,net_saved_chars) VALUES "
		.. table.concat(parts, ",") .. ";")
end

--- Inserts foreground transitions in the shared events_app_switch format.
--- @param device_id string Device identifier.
--- @param events table Array of {ts,date,prev_app,next_app,duration_ms}.
function M.insert_app_switch_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s',%d)",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("!%Y-%m-%d")),
			_sql_escape(ev.prev_app or ""),
			_sql_escape(ev.next_app or ""),
			tonumber(ev.duration_ms) or 0
		)
	end
	return _exec("INSERT OR IGNORE INTO events_app_switch "
		.. "(device_id,id,ts,date,prev_app,next_app,duration_ms) VALUES "
		.. table.concat(parts, ",") .. ";")
end

--- Upserts per-app daily aggregate counters into agg_app_day.
--- @param device_id string Device identifier.
--- @param date      string "YYYY-MM-DD".
--- @param app       string Application name.
--- @param fields    table  Field→value map (e.g. {chars=500, time_ms=120000}).
function M.upsert_app_day(device_id, date, app, fields)
	if not M.is_available() then return end
	if type(fields) ~= "table" then return end

	local allowed = {
		chars = true, time_ms = true, app_time_ms = true,
		hs_chars = true, hs_triggers = true, hs_input_chars = true,
		llm_chars = true, llm_triggers = true, llm_input_chars = true,
	}
	local sets = {}
	for k, v in pairs(fields) do
		if allowed[k] and type(v) == "number" and v > 0 then
			sets[#sets + 1] = string.format("%s = %s + %d",
				_sql_escape(k), _sql_escape(k), v)
		end
	end
	if #sets == 0 then return end

	local sql = string.format(
		"INSERT INTO agg_app_day (device_id, date, app, chars, time_ms, app_time_ms, hs_chars, hs_triggers, hs_input_chars, llm_chars, llm_triggers, llm_input_chars) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET %s;",
		_sql_escape(device_id),
		_sql_escape(date),
		_sql_escape(app),
		tonumber(fields.chars) or 0,
		tonumber(fields.time_ms) or 0,
		tonumber(fields.app_time_ms) or 0,
		tonumber(fields.hs_chars) or 0,
		tonumber(fields.hs_triggers) or 0,
		tonumber(fields.hs_input_chars) or 0,
		tonumber(fields.llm_chars) or 0,
		tonumber(fields.llm_triggers) or 0,
		tonumber(fields.llm_input_chars) or 0,
		table.concat(sets, ", ")
	)
	return _exec(sql)
end

--- Inserts or upserts n-gram counts into the ngram_chars table.
--- @param device_id string Device identifier.
--- @param date      string "YYYY-MM-DD".
--- @param app       string Application name.
--- @param ngrams    table  { [token] = count|{c=count,sources={source=count}} } map.
function M.upsert_ngrams(device_id, date, app, ngrams)
	if not M.is_available() then return end
	if type(ngrams) ~= "table" then return end

	local parts = {}
	for token, value in pairs(ngrams) do
		local count = type(value) == "table" and value.c or value
		local sources = type(value) == "table" and value.sources or nil
		if type(count) == "number" and count > 0 then
			local source_parts = {}
			for source, source_count in pairs(sources or {}) do
				if type(source) == "string" and type(source_count) == "number" and source_count > 0 then
					source_parts[#source_parts + 1] = string.format('"%s":%d',
						source:gsub('"', '\\"'), math.floor(source_count))
				end
			end
			local source_json = "{" .. table.concat(source_parts, ",") .. "}"
			parts[#parts + 1] = string.format(
				"('%s','%s','%s','%s',%d,0,0,0,'%s')",
				_sql_escape(device_id),
				_sql_escape(date),
				_sql_escape(app),
				_sql_escape(token),
				math.floor(count),
				_sql_escape(source_json)
			)
		end
	end
	if #parts == 0 then return end

	local sql = string.format(
		"INSERT INTO ngram_chars (device_id, date, app, token, c, td, cd, e, esrc_json) "
		.. "VALUES %s "
		.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
		.. "c = c + excluded.c, "
		.. "esrc_json = json_object("
		.. "'hotstring', COALESCE(json_extract(esrc_json, '$.hotstring'), 0) + COALESCE(json_extract(excluded.esrc_json, '$.hotstring'), 0), "
		.. "'llm', COALESCE(json_extract(esrc_json, '$.llm'), 0) + COALESCE(json_extract(excluded.esrc_json, '$.llm'), 0), "
		.. "'other', COALESCE(json_extract(esrc_json, '$.other'), 0) + COALESCE(json_extract(excluded.esrc_json, '$.other'), 0));",
		table.concat(parts, ",")
	)
	return _exec(sql)
end

--- Upserts physical Linux evdev scancodes. This is intentionally distinct
--- from ngram_chars: one key may emit different glyphs by layout/modifier, but
--- the scancode is the invariant physical location used by the heatmap.
--- @param scancodes table { [evdev_code] = count }.
function M.upsert_scancodes(device_id, date, app, scancodes)
	if not M.is_available() or type(scancodes) ~= "table" then return end
	local parts = {}
	for scancode, count in pairs(scancodes) do
		local code = tonumber(scancode)
		if code and code > 0 and type(count) == "number" and count > 0 then
			parts[#parts + 1] = string.format("('%s','%s','%s',%d,%d)",
				_sql_escape(device_id), _sql_escape(date), _sql_escape(app),
				math.floor(code), math.floor(count))
		end
	end
	if #parts == 0 then return true end
	return _exec("INSERT INTO ngram_scancodes (device_id, date, app, scancode, c) VALUES "
		.. table.concat(parts, ",")
		.. " ON CONFLICT(device_id, date, app, scancode) DO UPDATE SET c = c + excluded.c;")
end

--- Bumps the meta.rev counter so the view cache knows new data is available.
function M.bump_rev()
	if not M.is_available() then return end
	return _exec("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'rev';")
end

return M
