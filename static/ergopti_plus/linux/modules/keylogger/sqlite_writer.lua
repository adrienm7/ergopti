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
local TextCipher    = require("modules.keylogger.text_cipher")

-- How many session durations one application-day keeps. Read from the shared
-- accumulator rather than restated, because the walk caps the array it hands
-- over with the same number and two independent caps would disagree the day
-- either is tuned.
local SESSION_DURATIONS_CAP = require("keylogger.aggregator_helpers").SESSION_DURATIONS_CAP

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
	return (s:gsub("'", "''"))
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
	-- Through the shared resolver. This used to walk "../../../" from the driver
	-- root — two levels too high — and fall back to a BARE RELATIVE path, which
	-- made schema loading depend on the process's current directory rather than
	-- on where the driver is installed. Started from anywhere but one exact
	-- directory, the keylogger came up with no schema at all.
	local Paths = require("infra.paths")
	local schema_path = Paths.shared("data/db/schema.sql")
	if not schema_path then
		Logger.error(LOG, "Cannot locate the shared tree — schema.sql is unreachable.")
		return nil
	end

	local fh = io.open(schema_path, "r")
	if not fh then
		Logger.error(LOG, "Cannot read schema.sql at %s.", schema_path)
		return nil
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
		local event_id = first_id + i - 1

		-- `text` and `events_json` are the only columns holding what the user
		-- literally typed, so they are the only ones encrypted. Everything else
		-- is aggregate data the dashboard computes over, and encrypting it would
		-- cost every query a decryption it does not need.
		local raw_text = ev.text or ""
		local raw_json = ev.events_json or "[]"
		local enc_text = TextCipher.encrypt(device_id, event_id, raw_text)
		local enc_json = TextCipher.encrypt(device_id, tostring(event_id) .. "j", raw_json)
		if enc_text == nil or enc_json == nil then
			-- Encryption is on but could not run. Storing the plaintext would
			-- silently defeat the setting the user turned on, so drop the batch.
			Logger.error(LOG, "At-rest encryption failed — %d typing event(s) dropped rather than stored in clear.",
				#events)
			return false
		end

		local ts      = _sql_escape(ev.ts      or os.date("!%Y-%m-%d %H:%M:%S"))
		local date    = _sql_escape(ev.date    or os.date("!%Y-%m-%d"))
		local app     = _sql_escape(ev.app     or "unknown")
		local text    = _sql_escape(enc_text)
		local title   = _sql_escape(ev.title   or "")
		local wpm     = tonumber(ev.wpm) or 0
		local layout  = _sql_escape(ev.layout  or "")
		local events_json = _sql_escape(enc_json)

		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s','','',0,0,0,0,0,%d,0,0,0.0,'%s','','%s')",
			_sql_escape(device_id), event_id, ts, date, app, title,
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

--- Inserts shortcut firings — the actions a user triggers that type no text.
---
--- macOS has written this table since its keylogger existed; this driver wrote
--- nothing, so CapsWord, the selection transforms, the wrapping pairs and every
--- action an extension registers were invisible in the metrics. "What did I
--- actually use" is the question the dashboard exists to answer, and it could
--- only ever answer it about hotstrings here.
---
--- Both columns are TEXT NOT NULL: an event with no key name still records that
--- something fired, which is worth more than a row lost to INSERT OR IGNORE.
--- @param device_id string
--- @param events table Array of { ts, date, app, key }.
--- @return boolean|nil
function M.insert_shortcut_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s')",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("!%Y-%m-%d")),
			_sql_escape(ev.app or "unknown"),
			_sql_escape(ev.key or "")
		)
	end
	return _exec("INSERT OR IGNORE INTO events_shortcut "
		.. "(device_id,id,ts,date,app,key) VALUES "
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
		-- How many suggestions were OFFERED, as against the triggers above, which
		-- count the ones taken. The acceptance rate is the ratio of the two, and
		-- with the denominator never written it read as zero on a driver whose
		-- suggestions were being accepted all day.
		hs_suggested = true, llm_suggested = true,
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
		"INSERT INTO agg_app_day (device_id, date, app, chars, time_ms, app_time_ms, hs_chars, hs_triggers, hs_input_chars, llm_chars, llm_triggers, llm_input_chars, hs_suggested, llm_suggested) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d) "
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
		tonumber(fields.hs_suggested) or 0,
		tonumber(fields.llm_suggested) or 0,
		table.concat(sets, ", ")
	)
	return _exec(sql)
end

--- Upserts the per-app-day character-class breakdown.
---
--- The five counts are summed because a flush lands every few seconds and the
--- day's composition is their total. The first and last typed minute are not:
--- they are a MIN and a MAX, taken in SQL so a late flush cannot move the first
--- keystroke of the morning forward.
--- @param row table { date, app, letter, digit, punct, space, other,
---        first_typed_min?, last_typed_min? }
function M.upsert_chars_class(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local function quoted_or_null(value)
		if type(value) ~= "string" or value == "" then return "NULL" end
		return "'" .. _sql_escape(value) .. "'"
	end
	local sql = string.format(
		"INSERT INTO agg_app_day_chars_class "
		.. "(device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d,%d,%d,%s,%s) "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
		.. "letter = letter + excluded.letter, digit = digit + excluded.digit, "
		.. "punct = punct + excluded.punct, space = space + excluded.space, "
		.. "other = other + excluded.other, "
		.. "first_typed_min = MIN(COALESCE(first_typed_min, excluded.first_typed_min), "
		.. "COALESCE(excluded.first_typed_min, first_typed_min)), "
		.. "last_typed_min = MAX(COALESCE(last_typed_min, excluded.last_typed_min), "
		.. "COALESCE(excluded.last_typed_min, last_typed_min));",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.letter) or 0), math.floor(tonumber(row.digit) or 0),
		math.floor(tonumber(row.punct) or 0), math.floor(tonumber(row.space) or 0),
		math.floor(tonumber(row.other) or 0),
		quoted_or_null(row.first_typed_min), quoted_or_null(row.last_typed_min))
	return _exec(sql)
end

--- Upserts the per-app-day error analysis.
---
--- `cascade_max_len` is a MAX and everything else a sum, for the same reason:
--- the longest correction of the day does not get longer by being flushed twice.
--- @param row table { date, app, bs_total, cascade_count, cascade_max_len,
---        recovery_sum_ms, recovery_count }
function M.upsert_errors(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_errors "
		.. "(device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
		.. "bs_total = bs_total + excluded.bs_total, "
		.. "cascade_count = cascade_count + excluded.cascade_count, "
		.. "cascade_max_len = MAX(cascade_max_len, excluded.cascade_max_len), "
		.. "recovery_sum_ms = recovery_sum_ms + excluded.recovery_sum_ms, "
		.. "recovery_count = recovery_count + excluded.recovery_count;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.bs_total) or 0),
		math.floor(tonumber(row.cascade_count) or 0),
		math.floor(tonumber(row.cascade_max_len) or 0),
		math.floor(tonumber(row.recovery_sum_ms) or 0),
		math.floor(tonumber(row.recovery_count) or 0))
	return _exec(sql)
end

--- Upserts one hour of the activity histogram.
--- @param row table { date, app, hour, c, e, em, es }
function M.upsert_hourly(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es) "
		.. "VALUES ('%s','%s','%s','%s',%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
		.. "c = c + excluded.c, e = e + excluded.e, em = em + excluded.em, es = es + excluded.es;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(tostring(row.hour or "")),
		math.floor(tonumber(row.c) or 0), math.floor(tonumber(row.e) or 0),
		math.floor(tonumber(row.em) or 0), math.floor(tonumber(row.es) or 0))
	return _exec(sql)
end

--- Upserts one five-minute slot of the fine-grained activity histogram.
--- @param row table { date, app, slot, c, e, es }
function M.upsert_hourly_min5(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es) "
		.. "VALUES ('%s','%s','%s','%s',%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
		.. "c = c + excluded.c, e = e + excluded.e, es = es + excluded.es;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(tostring(row.slot or "")),
		math.floor(tonumber(row.c) or 0), math.floor(tonumber(row.e) or 0),
		math.floor(tonumber(row.es) or 0))
	return _exec(sql)
end

--- Upserts one pause-threshold bucket for an application-day.
---
--- The buckets are cumulative: a row for 5000 ms holds every delay at or below
--- five seconds, so the dashboard's "ignore pauses longer than…" control reads
--- one row and gets a total rather than a slice.
--- @param row table { date, app, bucket_ms, time_sum, credited }
function M.upsert_app_bucket(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET "
		.. "time_sum = time_sum + excluded.time_sum, credited = credited + excluded.credited;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.bucket_ms) or 0),
		math.floor(tonumber(row.time_sum) or 0),
		math.floor(tonumber(row.credited) or 0))
	return _exec(sql)
end

--- Upserts the per-app-day burst record.
---
--- `max_cpm` and `max_chars` are records and take a MAX; the counts and the
--- moment sums add. The length histogram is a JSON object merged in SQL, since
--- each flush only knows about the bursts it saw.
--- @param row table { date, app, count_total, max_cpm, max_chars, length_buckets,
---        inter_count, inter_sum, inter_sumsq }
function M.upsert_burst(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local parts = {}
	for label, count in pairs(row.length_buckets or {}) do
		if type(count) == "number" and count > 0 then
			parts[#parts + 1] = string.format('"%s":%d',
				tostring(label):gsub('"', '\\"'), math.floor(count))
		end
	end
	local buckets_json = "{" .. table.concat(parts, ",") .. "}"
	local sql = string.format(
		"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, "
		.. "length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) "
		.. "VALUES ('%s','%s','%s',%d,%f,%d,'%s',%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
		.. "count_total = count_total + excluded.count_total, "
		.. "max_cpm = MAX(max_cpm, excluded.max_cpm), "
		.. "max_chars = MAX(max_chars, excluded.max_chars), "
		-- Merged key by key rather than replaced: each flush sees only its own
		-- bursts, so overwriting would leave the histogram describing the last
		-- few seconds of the day.
		.. "length_buckets_json = (SELECT json_group_object(k, v) FROM ("
		.. "SELECT key AS k, SUM(value) AS v FROM ("
		.. "SELECT key, value FROM json_each(length_buckets_json) "
		.. "UNION ALL SELECT key, value FROM json_each(excluded.length_buckets_json)"
		.. ") GROUP BY key)), "
		.. "inter_delay_count = inter_delay_count + excluded.inter_delay_count, "
		.. "inter_delay_sum = inter_delay_sum + excluded.inter_delay_sum, "
		.. "inter_delay_sumsq = inter_delay_sumsq + excluded.inter_delay_sumsq;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.count_total) or 0),
		tonumber(row.max_cpm) or 0,
		math.floor(tonumber(row.max_chars) or 0),
		_sql_escape(buckets_json),
		math.floor(tonumber(row.inter_count) or 0),
		math.floor(tonumber(row.inter_sum) or 0),
		math.floor(tonumber(row.inter_sumsq) or 0))
	return _exec(sql)
end

--- Sets an application's category across every day it appears on.
---
--- Applied to every row rather than today's: a category is a property of the
--- application, not of a day. Writing only today would leave the dashboard's
--- own history grouped under whatever the application was called before, and
--- the user would have to re-categorise it once per day they wanted to look at.
--- @param app_name string
--- @param category string
--- @param score number Productivity score.
function M.set_app_category(device_id, app_name, category, score)
	if not M.is_available() then return false end
	if type(app_name) ~= "string" or app_name == "" then return false end
	if type(category) ~= "string" or category == "" then return false end
	local sql = string.format(
		"UPDATE agg_app_day SET category = '%s' WHERE device_id = '%s' AND app = '%s';",
		_sql_escape(category), _sql_escape(device_id), _sql_escape(app_name))
	local ok = _exec(sql)
	if ok then M.set_meta("app_score." .. app_name, tostring(math.floor(tonumber(score) or 0))) end
	return ok
end

--- Upserts the per-app-day ergonomic record.
---
--- The two streak columns are records and take a MAX; the focus latency sums.
--- A day's longest same-finger run does not get longer by being flushed twice.
--- @param row table { date, app, same_finger_streak_max, same_hand_streak_max,
---        auto_repeat_count, focus_to_first_key_sum_ms, focus_to_first_key_count }
function M.upsert_ergo(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, "
		.. "same_hand_streak_max, auto_repeat_count, focus_to_first_key_sum_ms, "
		.. "focus_to_first_key_count) VALUES ('%s','%s','%s',%d,%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
		.. "same_finger_streak_max = MAX(same_finger_streak_max, excluded.same_finger_streak_max), "
		.. "same_hand_streak_max = MAX(same_hand_streak_max, excluded.same_hand_streak_max), "
		.. "auto_repeat_count = auto_repeat_count + excluded.auto_repeat_count, "
		.. "focus_to_first_key_sum_ms = focus_to_first_key_sum_ms + excluded.focus_to_first_key_sum_ms, "
		.. "focus_to_first_key_count = focus_to_first_key_count + excluded.focus_to_first_key_count;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.same_finger_streak_max) or 0),
		math.floor(tonumber(row.same_hand_streak_max) or 0),
		math.floor(tonumber(row.auto_repeat_count) or 0),
		math.floor(tonumber(row.focus_to_first_key_sum_ms) or 0),
		math.floor(tonumber(row.focus_to_first_key_count) or 0))
	return _exec(sql)
end

--- Upserts one application-to-application transition count for a day.
---
--- The pair is the key, not just the destination: the panel this feeds asks
--- which application the user leaves to reach another, and a count keyed on the
--- destination alone cannot answer that.
--- @param row table { date, app_from, app_to, count }
function M.upsert_switch_to(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) "
		.. "VALUES ('%s','%s','%s','%s',%d) "
		.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET "
		.. "count = count + excluded.count;",
		_sql_escape(device_id), _sql_escape(row.date),
		_sql_escape(row.app_from), _sql_escape(row.app_to),
		math.floor(tonumber(row.count) or 0))
	return _exec(sql)
end

--- Upserts the per-app-day typing-session record.
---
--- The durations array is capped by the walk before it gets here, and truncated
--- again in SQL: a day of short sessions would otherwise grow one JSON array
--- without bound, and the dashboard only plots a sample of them.
--- @param row table { date, app, count_total, longest_ms, longest_chars,
---        total_active_ms, durations }
function M.upsert_session(device_id, row)
	if not M.is_available() or type(row) ~= "table" then return end
	local parts = {}
	for _, duration in ipairs(row.durations or {}) do
		parts[#parts + 1] = string.format("%d", math.floor(tonumber(duration) or 0))
	end
	local durations_json = "[" .. table.concat(parts, ",") .. "]"
	local sql = string.format(
		"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, "
		.. "longest_chars, total_active_ms, durations_json) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d,%d,'%s') "
		.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
		.. "count_total = count_total + excluded.count_total, "
		.. "longest_ms = MAX(longest_ms, excluded.longest_ms), "
		.. "longest_chars = MAX(longest_chars, excluded.longest_chars), "
		.. "total_active_ms = total_active_ms + excluded.total_active_ms, "
		.. "durations_json = (SELECT json_group_array(d) FROM ("
		.. "SELECT value AS d FROM json_each(durations_json) "
		.. "UNION ALL SELECT value FROM json_each(excluded.durations_json) "
		.. "LIMIT " .. SESSION_DURATIONS_CAP .. "));",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.count_total) or 0),
		math.floor(tonumber(row.longest_ms) or 0),
		math.floor(tonumber(row.longest_chars) or 0),
		math.floor(tonumber(row.total_active_ms) or 0),
		_sql_escape(durations_json))
	return _exec(sql)
end

-- Every n-gram family the shared schema declares, and the only names this
-- writer will target. A whitelist rather than a formatted parameter: the table
-- name cannot be escaped as a value, so an unchecked caller is an injection —
-- and the nine names are known at authoring time.
local NGRAM_TABLES = {
	ngram_chars = true, ngram_bigrams = true, ngram_trigrams = true,
	ngram_quadgrams = true, ngram_pentagrams = true, ngram_hexagrams = true,
	ngram_heptagrams = true, ngram_words = true, ngram_word_bigrams = true,
}

M.NGRAM_TABLES = NGRAM_TABLES

--- Inserts or upserts n-gram counts into one of the shared n-gram tables.
---
--- Took no table name until 2026-08-06 and always wrote ngram_chars, so this
--- driver produced single characters and nothing else. Eight of the nine
--- families the dashboard reads were empty by construction: the same-finger
--- bigram analysis, the word lists, the error analysis and the heatmap's
--- first/last counts all had nothing to read on Linux and rendered blank.
--- @param device_id string Device identifier.
--- @param date      string "YYYY-MM-DD".
--- @param app       string Application name.
--- @param ngrams    table  { [token] = count|{c=count,sources={source=count}} } map.
--- @param table_name string|nil One of NGRAM_TABLES; defaults to ngram_chars.
function M.upsert_ngrams(device_id, date, app, ngrams, table_name)
	if not M.is_available() then return end
	if type(ngrams) ~= "table" then return end
	local target = table_name or "ngram_chars"
	if not NGRAM_TABLES[target] then
		Logger.error(LOG, "upsert_ngrams(): '%s' is not an n-gram table — nothing written.",
			tostring(target))
		return
	end

	local parts = {}
	for token, value in pairs(ngrams) do
		local is_row  = type(value) == "table"
		local count   = is_row and value.c or value
		local sources = is_row and value.sources or nil
		-- Total delay, delay sample count and error count. Hardcoded to zero
		-- until 2026-08-06, which made every token read as free: the panel that
		-- ranks sequences by what they cost ranked a column of zeroes.
		local total_delay  = is_row and tonumber(value.td) or 0
		local delay_count  = is_row and tonumber(value.cd) or 0
		local error_count  = is_row and tonumber(value.e) or 0
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
				"('%s','%s','%s','%s',%d,%d,%d,%d,'%s')",
				_sql_escape(device_id),
				_sql_escape(date),
				_sql_escape(app),
				_sql_escape(token),
				math.floor(count),
				math.floor(total_delay or 0),
				math.floor(delay_count or 0),
				math.floor(error_count or 0),
				_sql_escape(source_json)
			)
		end
	end
	if #parts == 0 then return end

	local sql = string.format(
		"INSERT INTO " .. target .. " (device_id, date, app, token, c, td, cd, e, esrc_json) "
		.. "VALUES %s "
		.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
		.. "c = c + excluded.c, "
		-- Summed, not replaced: the mean delay for a token is td/cd across the
		-- whole day, and a flush lands every few seconds. Overwriting would
		-- leave the average describing the last handful of keystrokes.
		.. "td = td + excluded.td, "
		.. "cd = cd + excluded.cd, "
		.. "e = e + excluded.e, "
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

--- Runs an arbitrary SQL script through the same stdin path as every write.
--- Exposed for the at-rest migration, which rewrites rows this module wrote and
--- must not open a second, less careful route to the database: the script it
--- builds embeds the characters the user typed, so it may never touch /tmp.
--- @param sql string Complete SQL script.
--- @return boolean True on success.
function M.exec_sql(sql)
	if not M.is_available() then return false end
	if type(sql) ~= "string" or sql == "" then return false end
	return _exec(sql)
end

--- Runs a SELECT and returns its output lines.
--- @param sql string Complete SELECT statement.
--- @return table|nil One entry per output line, or nil when no database is open.
function M.query_rows(sql)
	if not M.is_available() then return nil end
	if type(sql) ~= "string" or sql == "" then return nil end
	local cmd = SqliteCommand.build(_db_path, sql, { flags = { "-noheader" } })
	if not cmd then return nil end
	local pipe = io.popen(cmd, "r")
	if not pipe then return nil end
	local lines = {}
	for line in pipe:lines() do lines[#lines + 1] = line end
	pipe:close()
	return lines
end

--- Reads one meta key. Used by the migration to resume where it stopped rather
--- than re-reading every row of a year-long history at each daemon start.
--- @param key string
--- @return string|nil The stored value, or nil when absent.
function M.get_meta(key)
	if not M.is_available() or type(key) ~= "string" or key == "" then return nil end
	return _query_scalar(string.format("SELECT value FROM meta WHERE key = '%s';", _sql_escape(key)))
end

--- Writes one meta key.
--- @param key   string
--- @param value string
--- @return boolean True on success.
function M.set_meta(key, value)
	if not M.is_available() or type(key) ~= "string" or key == "" then return false end
	return _exec(string.format("INSERT OR REPLACE INTO meta (key, value) VALUES ('%s', '%s');",
		_sql_escape(key), _sql_escape(tostring(value))))
end

--- Bumps the meta.rev counter so the view cache knows new data is available.
function M.bump_rev()
	if not M.is_available() then return end
	return _exec("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'rev';")
end

return M
