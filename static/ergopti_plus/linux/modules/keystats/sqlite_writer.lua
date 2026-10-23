--- modules/keystats/sqlite_writer.lua

--- ==============================================================================
--- MODULE: Keystats SQLite Writer (Linux)
--- DESCRIPTION:
--- Encapsulates SQLite interactions for the Linux keystats persistence layer.
--- Uses the `sqlite3` CLI binary (available on every Linux distro) via io.popen
--- — zero C-library vendoring required. Bootstraps the canonical schema from
--- _shared/data/db/schema.sql and provides INSERT helpers for the core event
--- and aggregate tables consumed by the shared metrics dashboard.
---
--- This module is the Linux counterpart to macOS's modules/keystats/sqlite_writer.lua
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
---    are not populated until the keystats-walker state machine is
---    wired on Linux.
--- 4. Graceful degradation: when the sqlite3 binary is absent, writer.is_available()
---    returns false and all write methods are silent no-ops — the daemon falls
---    back to JSON export.
--- ==============================================================================

local M = {}

local Logger        = require("logger.shim")
local SqliteCommand = require("modules.keystats.sqlite_command")
local TextCipher    = require("modules.keystats.text_cipher")
local EventIdPolicy = require("sqlite.event_id_policy")
local Json          = require("json")
local NativePath    = require("native_path")
local MediaStore    = require("keystats.media_store")

-- How many session durations one application-day keeps. Read from the shared
-- accumulator rather than restated, because the walk caps the array it hands
-- over with the same number and two independent caps would disagree the day
-- either is tuned.
local SESSION_DURATIONS_CAP = require("keystats.aggregator_helpers").SESSION_DURATIONS_CAP

local LOG = "modules.keystats.sqlite_writer"


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

-- Source-admitted media policy is separate from native capture admission.
local _media_policy = nil
-- A failed terminal observation may follow COMMIT. Retain its exact pipe owner
-- and block replacement rather than replaying caller-owned events ambiguously.
local _media_terminal_debt = nil

-- Pure formatters shared by standalone upserts and the atomic typing batch.
local _derived_sql = {}
local _raw_sql = {}
local _flush_owner = nil
local unpack_values = table.unpack or unpack


-- =========================================
-- =========================================
-- ======= 2/ Internal Helpers =============
-- =========================================
-- =========================================

--- Checks once whether the sqlite3 CLI binary is available.
--- @return boolean
local function _check_sqlite3()
	if _available ~= nil then return _available end
	-- command -v, the shell's own lookup: `which` is a separate package that
	-- Arch's base image and other minimal systems do not ship, and there the
	-- probe reported sqlite3 missing and switched metrics to the JSON fallback.
	local ok = os.execute("command -v sqlite3 >/dev/null 2>&1")
	_available = (ok == true or ok == 0)
	if not _available then
		Logger.warn(LOG, "sqlite3 CLI not found — SQLite persistence disabled.")
		Logger.warn(LOG, "  Install: sudo apt-get install sqlite3")
	end
	return _available
end

--- Escapes a string value for safe use inside a single-quoted SQL literal.
--- Preserves every text byte across SQLite's native CLI script boundary.
--- @param s string
--- @return string
local function _sql_escape(s)
	if type(s) ~= "string" then return "" end
	return SqliteCommand.escape_literal(s)
end

--- Runs a SQL statement against the database via the sqlite3 CLI.
--- @param sql string Complete SQL statement(s) to execute.
--- @return boolean True on success.
local function _exec(sql, media_owned)
	if _flush_owner and not _flush_owner:is_settled() then return false end
	if not _db_path or not _available then return false end

	-- The script carries the characters the user typed, so it travels on stdin.
	-- Staging it in /tmp is what turned this module into a keystroke leak.
	-- Results are discarded so that only errors reach the pipe: the schema's
	-- "PRAGMA journal_mode = DELETE" prints "delete", which read as a failure
	-- and put every first start on the JSON fallback.
	local cmd, reason = SqliteCommand.build(_db_path, ".output /dev/null\n" .. sql,
		{ capture_stderr = true, capture_exit = true })
	if not cmd then
		Logger.error(LOG, "Cannot compose the sqlite3 command: %s.", reason)
		return false
	end

	local pipe = io.popen(cmd, "r")
	if not pipe then
		Logger.error(LOG, "Cannot spawn the sqlite3 CLI.")
		return false
	end
	local output
	if media_owned then
		local read_ok, body = pcall(pipe.read, pipe, "*a")
		local close_ok, closed = pcall(pipe.close, pipe)
		if not read_ok or type(body) ~= "string" or not close_ok or closed ~= true then
			_media_terminal_debt = { pipe = pipe, close_acknowledged = close_ok and closed == true }
			_db_path = nil
			Logger.error(LOG, "Semantic media terminal observation failed; exact owner and pending events remain unresolved.")
			return false
		end
		output = body
	else
		output = pipe:read("*a")
		pipe:close()
	end
	local accepted, err_out, receipt_error = SqliteCommand.read_exit_receipt(output)
	if media_owned and ((not accepted and (receipt_error == "missing SQLite exit receipt"
		or receipt_error == "invalid SQLite exit receipt")) or (accepted and err_out ~= "")) then
		_media_terminal_debt = { pipe = pipe, close_acknowledged = true }
		_db_path = nil
	end

	if err_out ~= "" then
		-- These statements select nothing, and stderr is merged into stdout, so
		-- any output at all means the script failed.
		Logger.error(LOG, "SQLite error: %s", SqliteCommand.sanitise_error(err_out))
		return false
	end
	if not accepted then
		Logger.error(LOG, "SQLite write refused: %s.", receipt_error)
		return false
	end
	return true
end

--- Commits one raw or derived batch without exposing partially refused rows.
--- SQLite FAIL can retain earlier rows and trigger effects in autocommit mode.
--- A failed script exits before COMMIT and its connection rolls the batch back;
--- the existing receipt acknowledges COMMIT, not merely the INSERT statement.
--- @param sql string One composed raw or derived INSERT statement.
--- @return boolean
local function _exec_raw_batch(sql)
	return _exec("BEGIN IMMEDIATE;\n" .. sql .. "\nCOMMIT;")
end

--- Runs a read query and rejects any rows from a failed native CLI.
--- @param sql string Complete SELECT statement.
--- @return string|nil Complete output, or nil when the query fails.
local function _query_output(sql)
	if not _db_path or not _available then return nil end
	local cmd = SqliteCommand.build(_db_path, sql, { flags = { "-noheader" }, capture_exit = true })
	if not cmd then return nil end
	local pipe = io.popen(cmd, "r")
	if not pipe then return nil end
	local output = pipe:read("*a")
	pipe:close()
	local accepted, body, reason = SqliteCommand.read_exit_receipt(output)
	if not accepted then
		Logger.warn(LOG, "SQLite read refused: %s.", reason)
		return nil
	end
	return body
end

--- Runs a scalar SELECT through the sqlite3 CLI.
--- @param sql string Complete SELECT statement.
--- @return string|nil First output line, or nil when the query fails.
local function _query_scalar(sql)
	local output = _query_output(sql)
	if output == nil or output == "" then return nil end
	return output:match("^([^\n]*)")
end

--- Reserves consecutive event IDs durably across independent writer processes.
--- @param count number Number of IDs required.
--- @return number|nil First reserved ID after the transaction commits.
local function _reservation_sql(count)
	return string.format([[
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO meta (key, value) VALUES ('linux_next_event_id', '1');
UPDATE meta SET value = CAST(value AS INTEGER) + %d
WHERE key = 'linux_next_event_id'
  AND instr(value, char(0)) = 0
  AND trim(value) <> '' AND trim(value) NOT GLOB '*[^0-9]*'
  AND CAST(value AS INTEGER) > 0
  AND typeof(CAST(value AS INTEGER) + %d) = 'integer'
  AND CAST(value AS INTEGER) <= %d - %d;
SELECT CAST(value AS INTEGER) - %d FROM meta
WHERE key = 'linux_next_event_id' AND changes() = 1;
COMMIT;
]], count, count, EventIdPolicy.MAX_EXACT_LUA_CURSOR, count, count)
end

local function _reserve_event_ids(count)
	count = math.max(1, math.floor(tonumber(count) or 1))
	if not M.is_available() then return nil end
	-- Read and advance the shared cursor under one native write lock. A cached
	-- cursor reused another collector's IDs, and INSERT OR IGNORE then silently
	-- discarded acknowledged raw rows. The exit receipt also covers COMMIT:
	-- an emitted SELECT result alone never acknowledges the reservation.
	-- SQLite CAST accepts numeric prefixes and clamps overflowing integers. Admit
	-- decimal positive cursor text before casting, and keep the advanced cursor
	-- within Lua's exact integer range. A rejected UPDATE emits no allocated ID.
	local first = tonumber(_query_scalar(_reservation_sql(count)))
	if not first then Logger.error(LOG, "Event ID reservation was not acknowledged.") end
	return first
end

--- Reads the canonical schema file from the _shared tree.
--- @return string|nil Schema SQL, or nil on failure.
local function _read_schema()
	-- Through the shared resolver. This used to walk "../../../" from the driver
	-- root — two levels too high — and fall back to a BARE RELATIVE path, which
	-- made schema loading depend on the process's current directory rather than
	-- on where the driver is installed. Started from anywhere but one exact
	-- directory, the keystats came up with no schema at all.
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

--- Reads packaged media data through the existing classified native file port.
local function _read_media_resource(relative)
	local path = require("infra.paths").shared(relative)
	if type(path) ~= "string" then return nil end
	local body, status = require("adapters.file_system").read_with_status(path)
	if status ~= "ok" or type(body) ~= "string" then
		Logger.error(LOG, "Cannot read packaged semantic media resource.")
		return nil
	end
	return body
end

--- Admits only the committed five-key policy and additive schema before writes.
local function _ensure_media_schema()
	local schema = _read_media_resource("data/db/media_schema.sql")
	local catalogue = _read_media_resource("data/keycodes/metrics_media_keys.json")
	if schema == nil or catalogue == nil then return false end
	local ok, policy, transaction = pcall(function()
		return MediaStore.policy(Json.decode(catalogue)), MediaStore.schema_transaction(schema)
	end)
	if not ok then
		Logger.error(LOG, "Semantic media schema or catalogue admission refused.")
		return false
	end
	if not _exec(transaction, true) then return false end
	_media_policy = policy
	return true
end

--- Upgrades databases created before Linux was accepted by devices.os.
--- The raw event tables deliberately have no foreign keys, but registration
--- must still succeed so the database remains portable across all three OSes.
local function _ensure_linux_device_schema()
	-- sqlite_master preserves multiline DDL. The scalar helper reads only its
	-- first line, so it missed the existing Linux CHECK and rebuilt the current
	-- registry on every start, dropping indexes and requiring a write lock.
	local current_sql = _query_output("SELECT sql FROM sqlite_master WHERE type='table' AND name='devices';") or ""
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

--- Reports the separate capability required for owned asynchronous flushes.
--- A minimal daemon without luv may still read the last committed database.
--- @return boolean
function M.flush_transport_available()
	return require("infra.sqlite_batch_process").is_available() == true
end

--- Opens (or creates) the SQLite database at the given path and bootstraps the
--- canonical schema on first open.
--- @param db_path string Absolute path to the .sqlite file (e.g. ~/.local/share/ergopti/metrics.sqlite).
--- @return boolean True on success.
function M.open_db(db_path)
	if _flush_owner and not _flush_owner:is_settled() then return false end
	if _media_terminal_debt ~= nil then
		Logger.error(LOG, "Cannot reopen SQLite while semantic media terminal ownership is unresolved.")
		return false
	end
	if type(db_path) ~= "string" or db_path == "" then
		Logger.error(LOG, "open_db(): db_path must be a non-empty string.")
		return false
	end

	-- Bootstrap and schema admission belong to the open store. Repointing it
	-- would reuse the old admission and a later refusal would lose that owner.
	if _db_path ~= nil and _db_path ~= db_path then
		Logger.error(LOG, "Cannot switch SQLite stores before explicitly closing the current store.")
		return false
	end

	if not _check_sqlite3() then return false end

	_db_path = db_path

	-- Ensure the parent directory exists.
	local dir = NativePath.dirname(db_path) or "."
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

	if not _ensure_media_schema() then
		_media_policy = nil
		_db_path = nil
		return false
	end

	Logger.debug(LOG, "SQLite database open: %s", _db_path)
	return true
end

--- Closes the database connection (no-op for CLI-based backend, but cleans up state).
function M.close_db()
	if _flush_owner and not _flush_owner:is_settled() then return false end
	if _media_terminal_debt ~= nil then
		Logger.error(LOG, "Semantic media terminal cleanup remains unresolved; ambiguous pipe close is not retried.")
		return false
	end
	_media_policy = nil
	_db_path = nil
	_bootstrapped = false
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
--- @return boolean True only when the native registration write is acknowledged.
function M.register_device(device_id, device_name, os_name, os_version, host_signature)
	if not M.is_available() then return false end

	local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local sql = string.format([[
BEGIN IMMEDIATE;
INSERT INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at)
VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s')
ON CONFLICT(device_id) DO UPDATE SET
  name = excluded.name,
  os = excluded.os,
  os_version = excluded.os_version,
  host_signature = excluded.host_signature,
  updated_at = excluded.updated_at;
COMMIT;
]],
		_sql_escape(device_id),
		_sql_escape(device_name or device_id),
		_sql_escape(os_name or "linux"),
		_sql_escape(os_version or ""),
		_sql_escape(host_signature or device_id),
		now, now
	)
	-- Refresh host metadata without replacing creation/import fields or schema
	-- extensions this registration does not own. REPLACE deleted that history.
	-- FAIL in an AFTER trigger can retain a partial autocommit update. Keep the
	-- registration in one explicit transaction; -bail closes and rolls it back
	-- after a refused statement or COMMIT, before the terminal receipt returns.
	local accepted = _exec(sql)
	if accepted then Logger.debug(LOG, "Device registered.") end
	return accepted
end

--- Stores already admitted semantic media entries in one native transaction.
--- This port grants no native capture authority and never mutates pending input.
--- @param device_id string Persisted collector partition, not a fabricated source device.
--- @param events table Caller-owned admitted media press/release entries.
--- @param threshold_ms integer Shared inclusive tap threshold.
--- @return boolean committed Exact terminal COMMIT and pipe-close acknowledgement.
function M.insert_media_events(device_id, events, threshold_ms)
	if not M.is_available() or _media_policy == nil or _media_terminal_debt ~= nil then return false end
	local ok, plan = pcall(function()
		assert(type(events) == "table" and #events > 0, "Media batch requires events")
		local captured = {}
		for key in pairs(events) do
			assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #events, "Media batch must be dense")
		end
		for index = 1, #events do
			local source = events[index]
			assert(type(source) == "table", "Media event is missing")
			local event = {}
			for key, value in pairs(source) do event[key] = value end
			captured[index] = event
			MediaStore.raw_sql(device_id, index, event, Json.encode)
		end
		local batch = { media_ngram = {}, media_hold = {} }
		MediaStore.replay(_media_policy, batch, captured, threshold_ms)
		local derived = {}
		for _, row in pairs(batch.media_ngram) do derived[#derived + 1] = MediaStore.press_sql(device_id, row) end
		for _, row in pairs(batch.media_hold) do derived[#derived + 1] = MediaStore.hold_sql(device_id, row) end
		return { events = captured, derived = derived }
	end)
	if not ok then
		Logger.error(LOG, "Semantic media input admission refused.")
		return false
	end
	local first_id = _reserve_event_ids(#plan.events)
	if not first_id then return false end
	local statements = {}
	for index, event in ipairs(plan.events) do
		statements[#statements + 1] = MediaStore.raw_sql(device_id, first_id + index - 1, event, Json.encode)
	end
	for _, sql in ipairs(plan.derived) do statements[#statements + 1] = sql end
	statements[#statements + 1] = "UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='rev';"
	return _exec("BEGIN IMMEDIATE;\n" .. table.concat(statements, "\n") .. "\nCOMMIT;", true)
end

--- Rebuilds only one collector's semantic projections under the shared SQL lock.
--- @param device_id string Exact collector partition.
--- @param threshold_ms integer Shared inclusive tap threshold.
--- @return boolean committed
function M.rebuild_media(device_id, threshold_ms)
	if not M.is_available() or _media_policy == nil or _media_terminal_debt ~= nil then return false end
	local ok, sql = pcall(MediaStore.rebuild_sql, device_id, threshold_ms)
	if not ok then return false end
	return _exec("BEGIN IMMEDIATE;\n" .. sql
		.. "\nUPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='rev';\nCOMMIT;", true)
end

--- Inserts a batch of keystroke events into the events_typing table.
--- Each event is a single keystroke row.
---
--- NOTE: the full keystats-walker processes individual keystrokes into
--- bursts, sessions, and ergo stats. Until that walker is wired on Linux, this
--- method records a single summary row per flush cycle — enough for the
--- dashboard to show daily totals and n-grams.
---
--- @param device_id  string   Device identifier.
--- @param events     table    Array of { ts, date, app, text, wpm?, layout? } event tables.
--- @param derived table|nil Optional { ngrams, daily } rows committed with their raw source.
_raw_sql.typing = function(device_id, events, first_id, derived)

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
		local date    = _sql_escape(ev.date    or os.date("%Y-%m-%d"))
		local app     = _sql_escape(ev.app     or "unknown")
		local text    = _sql_escape(enc_text)
		local title   = _sql_escape(ev.title   or "")
		-- WPM is a fractional rate in a REAL column, not an integer counter.
		local wpm     = tonumber(ev.wpm) or 0
		local layout  = _sql_escape(ev.layout  or "")
		local events_json = _sql_escape(enc_json)

		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s','','','%s','',0,0,0,0,0,0,0,0.0,%.17g,'%s','','%s')",
			_sql_escape(device_id), event_id, ts, date, app, title,
			layout, wpm, text, events_json
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
	if derived ~= nil then
		local composed, statements = pcall(function()
			assert(type(derived) == "table" and type(derived.ngrams) == "table" and type(derived.daily) == "table")
			local out = { sql }
			for _, group in ipairs(derived.ngrams) do
				out[#out + 1] = assert(_derived_sql.ngrams(device_id, group.date, group.app, group.ngrams, group.table_name))
			end
			local families = {
				chars_class = "chars_class", errors = "errors", hourly = "hourly", hourly_min5 = "hourly_min5",
				app_buckets = "app_bucket", bursts = "burst", sessions = "session", ergo = "ergo", layouts = "layout",
			}
			for family, rows in pairs(derived.daily) do
				local formatter = assert(_derived_sql[assert(families[family])])
				assert(type(rows) == "table")
				for _, row in ipairs(rows) do out[#out + 1] = assert(formatter(device_id, row)) end
			end
			return table.concat(out, "\n")
		end)
		if not composed then
			Logger.error(LOG, "Typing batch derived SQL composition refused; pending source remains unacknowledged.")
			return false
		end
		sql = statements
	end
	return sql
end

--- Commits one canonical raw typing batch and returns its native receipt.
function M.insert_typing_events(device_id, events, derived)
	if not M.is_available() then return end
	if type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local sql = _raw_sql.typing(device_id, events, first_id, derived)
	if not sql then return false end
	return _exec_raw_batch(sql)
end

--- Inserts canonical hotstring events matching the macOS/Windows table shape.
--- @param device_id string Device identifier.
--- @param events table Array of {ts,date,app,kind,trigger,replacement,h_type,net_saved_chars}.
_raw_sql.hotstrings = function(device_id, events, first_id)
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s','%s','%s','%s',%d)",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("%Y-%m-%d")),
			_sql_escape(ev.app or "unknown"),
			_sql_escape(ev.kind or "fired"),
			_sql_escape(ev.trigger or ""),
			_sql_escape(ev.replacement or ""),
			_sql_escape(ev.h_type or "unknown"),
			tonumber(ev.net_saved_chars) or 0
		)
	end
	return "INSERT OR IGNORE INTO events_hotstring "
		.. "(device_id,id,ts,date,app,kind,trigger,replacement,h_type,net_saved_chars) VALUES "
		.. table.concat(parts, ",") .. ";"
end

--- Commits one canonical raw hotstrings batch and returns its native receipt.
function M.insert_hotstring_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local sql = _raw_sql.hotstrings(device_id, events, first_id)
	if not sql then return false end
	return _exec_raw_batch(sql)
end

--- Inserts shortcut firings — the actions a user triggers that type no text.
---
--- macOS has written this table since its keystats existed; this driver wrote
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
_raw_sql.shortcuts = function(device_id, events, first_id)
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s')",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("%Y-%m-%d")),
			_sql_escape(ev.app or "unknown"),
			_sql_escape(ev.key or "")
		)
	end
	return "INSERT OR IGNORE INTO events_shortcut "
		.. "(device_id,id,ts,date,app,key) VALUES "
		.. table.concat(parts, ",") .. ";"
end

--- Commits one canonical raw shortcuts batch and returns its native receipt.
function M.insert_shortcut_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local sql = _raw_sql.shortcuts(device_id, events, first_id)
	if not sql then return false end
	return _exec_raw_batch(sql)
end

--- Inserts foreground transitions in the shared events_app_switch format.
--- @param device_id string Device identifier.
--- @param events table Array of {ts,date,prev_app,next_app,duration_ms}.
_raw_sql.switches = function(device_id, events, first_id)
	local parts = {}
	for i, ev in ipairs(events) do
		parts[#parts + 1] = string.format(
			"('%s',%d,'%s','%s','%s','%s',%d)",
			_sql_escape(device_id), first_id + i - 1,
			_sql_escape(ev.ts or os.date("!%Y-%m-%d %H:%M:%S")),
			_sql_escape(ev.date or os.date("%Y-%m-%d")),
			_sql_escape(ev.prev_app or ""),
			_sql_escape(ev.next_app or ""),
			tonumber(ev.duration_ms) or 0
		)
	end
	return "INSERT OR IGNORE INTO events_app_switch "
		.. "(device_id,id,ts,date,prev_app,next_app,duration_ms) VALUES "
		.. table.concat(parts, ",") .. ";"
end

--- Commits one canonical raw switches batch and returns its native receipt.
function M.insert_app_switch_events(device_id, events)
	if not M.is_available() or type(events) ~= "table" or #events == 0 then return end
	local first_id = _reserve_event_ids(#events)
	if not first_id then return false end
	local sql = _raw_sql.switches(device_id, events, first_id)
	if not sql then return false end
	return _exec_raw_batch(sql)
end

--- Upserts per-app daily aggregate counters into agg_app_day.
--- @param device_id string Device identifier.
--- @param date      string "YYYY-MM-DD".
--- @param app       string Application name.
--- @param fields    table  Field→value map (e.g. {chars=500, time_ms=120000}).
_derived_sql.app_day = function(device_id, date, app, fields)
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
	return sql
end

--- Commits one canonical app day upsert and returns its native receipt.
function M.upsert_app_day(device_id, date, app, fields)
	if not M.is_available() then return end
	local sql = _derived_sql.app_day(device_id, date, app, fields)
	if not sql then return end
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
_derived_sql.chars_class = function(device_id, row)
	if type(row) ~= "table" then return end
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
	return sql
end

--- Commits one canonical chars class upsert and returns its native receipt.
function M.upsert_chars_class(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.chars_class(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts the per-app-day error analysis.
---
--- `cascade_max_len` is a MAX and everything else a sum, for the same reason:
--- the longest correction of the day does not get longer by being flushed twice.
--- @param row table { date, app, bs_total, cascade_count, cascade_max_len,
---        recovery_sum_ms, recovery_count }
_derived_sql.errors = function(device_id, row)
	if type(row) ~= "table" then return end
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
	return sql
end

--- Commits one canonical errors upsert and returns its native receipt.
function M.upsert_errors(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.errors(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Merges cumulative numeric histogram deltas using the existing burst SQL policy.
--- The object is spelled with json_quote rather than json_group_object, which
--- cuts a key at an embedded NUL: "a\u0000b" came back as "a", merged into a
--- second "a" key and the stored map stopped describing what was counted.
--- @param column string Owned histogram column.
--- @return string
local function number_map_merge_sql(column)
	return column .. " = (SELECT COALESCE('{' || group_concat(json_quote(k) || ':' || v, ',') || '}', '{}') FROM ("
		.. "SELECT key AS k, SUM(value) AS v FROM ("
		.. "SELECT key, value FROM json_each(" .. column .. ") "
		.. "UNION ALL SELECT key, value FROM json_each(excluded." .. column .. ")"
		.. ") GROUP BY key))"
end

--- Upserts one hour of the activity histogram.
--- @param row table { date, app, hour, c, e, em, es, e_buckets? }
_derived_sql.hourly = function(device_id, row)
	if type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) "
		.. "VALUES ('%s','%s','%s','%s',%d,%d,%d,%d,'%s') "
		.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
		.. "c = c + excluded.c, e = e + excluded.e, em = em + excluded.em, es = es + excluded.es, "
		.. number_map_merge_sql("e_buckets_json") .. ";",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(tostring(row.hour or "")),
		math.floor(tonumber(row.c) or 0), math.floor(tonumber(row.e) or 0),
		math.floor(tonumber(row.em) or 0), math.floor(tonumber(row.es) or 0),
		_sql_escape(Json.encode(row.e_buckets or {})))
	return sql
end

--- Commits one canonical hourly upsert and returns its native receipt.
function M.upsert_hourly(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.hourly(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts one five-minute slot of the fine-grained activity histogram.
--- @param row table { date, app, slot, c, e, es, e_buckets? }
_derived_sql.hourly_min5 = function(device_id, row)
	if type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) "
		.. "VALUES ('%s','%s','%s','%s',%d,%d,%d,'%s') "
		.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
		.. "c = c + excluded.c, e = e + excluded.e, es = es + excluded.es, "
		.. number_map_merge_sql("e_buckets_json") .. ";",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(tostring(row.slot or "")),
		math.floor(tonumber(row.c) or 0), math.floor(tonumber(row.e) or 0),
		math.floor(tonumber(row.es) or 0), _sql_escape(Json.encode(row.e_buckets or {})))
	return sql
end

--- Commits one canonical hourly min5 upsert and returns its native receipt.
function M.upsert_hourly_min5(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.hourly_min5(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts one pause-threshold bucket for an application-day.
---
--- The buckets are cumulative: a row for 5000 ms holds every delay at or below
--- five seconds, so the dashboard's "ignore pauses longer than…" control reads
--- one row and gets a total rather than a slice.
--- @param row table { date, app, bucket_ms, time_sum, credited }
_derived_sql.app_bucket = function(device_id, row)
	if type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited) "
		.. "VALUES ('%s','%s','%s',%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET "
		.. "time_sum = time_sum + excluded.time_sum, credited = credited + excluded.credited;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(tonumber(row.bucket_ms) or 0),
		math.floor(tonumber(row.time_sum) or 0),
		math.floor(tonumber(row.credited) or 0))
	return sql
end

--- Commits one canonical app bucket upsert and returns its native receipt.
function M.upsert_app_bucket(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.app_bucket(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts the per-app-day burst record.
---
--- `max_cpm` and `max_chars` are records and take a MAX; the counts and the
--- moment sums add. The length histogram is a JSON object merged in SQL, since
--- each flush only knows about the bursts it saw.
--- @param row table { date, app, count_total, max_cpm, max_chars, length_buckets,
---        inter_count, inter_sum, inter_sumsq }
_derived_sql.burst = function(device_id, row)
	if type(row) ~= "table" then return end
	local parts = {}
	for label, count in pairs(row.length_buckets or {}) do
		if type(count) == "number" and count > 0 then
			parts[#parts + 1] = string.format('%s:%d',
				Json.encode(tostring(label)), math.floor(count))
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
		.. number_map_merge_sql("length_buckets_json") .. ", "
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
	return sql
end

--- Commits one canonical burst upsert and returns its native receipt.
function M.upsert_burst(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.burst(device_id, row)
	if not sql then return end
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
	-- Category and score are one edit. Native -bail closes an unfinished
	-- transaction after a statement error, undoing even an AFTER trigger FAIL.
	local sql = string.format([[
BEGIN;
UPDATE agg_app_day SET category = '%s' WHERE device_id = '%s' AND app = '%s';
INSERT OR REPLACE INTO meta (key, value) VALUES ('%s', '%s');
COMMIT;
]],
		_sql_escape(category), _sql_escape(device_id), _sql_escape(app_name),
		_sql_escape("app_score." .. app_name), _sql_escape(tostring(math.floor(tonumber(score) or 0))))
	return _exec(sql)
end

-- How many window titles one application-day keeps. From the shared accumulator
-- so the three drivers cap at the same place; the schema's own comment says the
-- trimming belongs to the ingest pipeline, which is here.
local TITLE_CAP_PER_APP_DAY =
	require("keystats.aggregator_helpers").TITLE_CAP_PER_APP_DAY

--- Upserts one window title's counters for an application-day.
---
--- Trimmed after the insert rather than before: which titles survive depends on
--- every title of the day, and the caller only knows the ones in this flush.
--- Lowest (c + ms) first, so a window the user glanced at loses to one they
--- worked in.
--- @param row table { date, app, title, c, ms }
_derived_sql.title = function(device_id, row)
	if type(row) ~= "table" then return end
	if type(row.title) ~= "string" or row.title == "" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) "
		.. "VALUES ('%s','%s','%s','%s',%d,%d) "
		.. "ON CONFLICT(device_id, date, app, title) DO UPDATE SET "
		.. "c = c + excluded.c, ms = ms + excluded.ms; "
		.. "DELETE FROM agg_app_day_titles WHERE device_id = '%s' AND date = '%s' "
		.. "AND app = '%s' AND title NOT IN ("
		.. "SELECT title FROM agg_app_day_titles WHERE device_id = '%s' AND date = '%s' "
		.. "AND app = '%s' ORDER BY (c + ms) DESC LIMIT %d);",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(row.title),
		math.floor(tonumber(row.c) or 0), math.floor(tonumber(row.ms) or 0),
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(TITLE_CAP_PER_APP_DAY))
	return sql
end

--- Commits one canonical title upsert and returns its native receipt.
function M.upsert_title(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.title(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Reads the exact collector device/day baseline without aggregating devices.
--- @param device_id string Collector identity.
--- @param date string Calendar day.
--- @return table|nil row Persisted cumulative row, or nil when absent.
--- @return boolean accepted False when the native read or row is refused.
function M.read_system_day(device_id, date)
	if not M.is_available() or type(device_id) ~= "string" or device_id == ""
		or type(date) ~= "string" or date == "" then return nil, false end
	local fields = {
		"wifi_changes", "space_switches", "battery_sum", "battery_count", "battery_min",
		"battery_max", "audio_muted_ms", "locked_ms", "sleep_ms", "awake_ms",
		"passive_count", "night_wake_count",
	}
	local pairs = { "'date',date" }
	for _, field in ipairs(fields) do pairs[#pairs + 1] = "'" .. field .. "'," .. field end
	local body = _query_output("SELECT json_object(" .. table.concat(pairs, ",")
		.. ") FROM agg_system_day WHERE device_id='" .. _sql_escape(device_id)
		.. "' AND date='" .. _sql_escape(date) .. "';")
	if body == nil then return nil, false end
	if body == "" then return nil, true end
	local ok, row = pcall(Json.decode_lossless, body)
	if not ok or type(row) ~= "table" or Json.is_array(row) or Json.is_null(row)
		or row.date ~= date then return nil, false end
	for _, field in ipairs(fields) do
		local value = row[field]
		if Json.is_null(value) then value = nil end
		if value == nil and (field == "battery_sum" or field == "battery_count") then value = 0 end
		if value == nil and (field == "battery_min" or field == "battery_max") then
			row[field] = nil
		elseif type(value) == "number" then
			row[field] = value
		else
			return nil, false
		end
	end
	return row, true
end

--- Upserts the machine's own state for a day.
---
--- Every duration sums; the battery bounds are a MIN and a MAX. Sent as the
--- running total rather than as a delta, and the row REPLACES rather than adds,
--- because the sampler holds one accumulating day in memory — adding would
--- count every earlier minute again on each flush.
--- @param row table The accumulated day from system_metrics.
_derived_sql.system_day = function(device_id, row)
	if type(row) ~= "table" then return end
	if type(row.date) ~= "string" or row.date == "" then return end
	local function number_or_null(value)
		local n = tonumber(value)
		if not n then return "NULL" end
		return string.format("%d", math.floor(n))
	end
	local sql = string.format(
		"INSERT INTO agg_system_day (device_id, date, wifi_changes, space_switches, "
		.. "battery_sum, battery_count, battery_min, battery_max, audio_muted_ms, "
		.. "locked_ms, sleep_ms, awake_ms, passive_count, night_wake_count) "
		.. "VALUES ('%s','%s',%d,%d,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date) DO UPDATE SET "
		.. "wifi_changes = excluded.wifi_changes, space_switches = excluded.space_switches, "
		.. "battery_sum = excluded.battery_sum, battery_count = excluded.battery_count, "
		.. "battery_min = excluded.battery_min, battery_max = excluded.battery_max, "
		.. "audio_muted_ms = excluded.audio_muted_ms, locked_ms = excluded.locked_ms, "
		.. "sleep_ms = excluded.sleep_ms, awake_ms = excluded.awake_ms, "
		.. "passive_count = excluded.passive_count, night_wake_count = excluded.night_wake_count;",
		_sql_escape(device_id), _sql_escape(row.date),
		math.floor(tonumber(row.wifi_changes) or 0),
		math.floor(tonumber(row.space_switches) or 0),
		number_or_null(row.battery_sum), number_or_null(row.battery_count),
		number_or_null(row.battery_min), number_or_null(row.battery_max),
		math.floor(tonumber(row.audio_muted_ms) or 0),
		math.floor(tonumber(row.locked_ms) or 0),
		math.floor(tonumber(row.sleep_ms) or 0),
		math.floor(tonumber(row.awake_ms) or 0),
		math.floor(tonumber(row.passive_count) or 0),
		math.floor(tonumber(row.night_wake_count) or 0))
	return sql
end

--- Commits one canonical system day upsert and returns its native receipt.
function M.upsert_system_day(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.system_day(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts one key's hold statistics for an application-day.
---
--- The tap and hold counts are what make this table worth having on a keyboard
--- whose whole design is dual-role keys: the average alone cannot say whether a
--- key is being used both ways or neither.
--- @param row table { date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count }
_derived_sql.kc_hold = function(device_id, row)
	if type(row) ~= "table" then return end
	local keycode = tonumber(row.keycode)
	if not keycode then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, "
		.. "max_ms, tap_count, hold_count) VALUES ('%s','%s','%s',%d,%d,%d,%d,%d,%d) "
		.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET "
		.. "sum_ms = sum_ms + excluded.sum_ms, count = count + excluded.count, "
		-- A record, not a sum: the longest hold of the day does not get longer by
		-- being flushed twice.
		.. "max_ms = MAX(max_ms, excluded.max_ms), "
		.. "tap_count = tap_count + excluded.tap_count, "
		.. "hold_count = hold_count + excluded.hold_count;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		math.floor(keycode),
		math.floor(tonumber(row.sum_ms) or 0), math.floor(tonumber(row.count) or 0),
		math.floor(tonumber(row.max_ms) or 0),
		math.floor(tonumber(row.tap_count) or 0), math.floor(tonumber(row.hold_count) or 0))
	return sql
end

--- Commits one canonical kc hold upsert and returns its native receipt.
function M.upsert_kc_hold(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.kc_hold(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts how many keystrokes an application-day saw under one layout.
---
--- One row per (app, layout) rather than a single "current layout" column: a
--- day spent switching between two of them is two rows, and a column would have
--- to pick one and call the rest of the day a lie.
--- @param row table { date, app, layout, count }
_derived_sql.layout = function(device_id, row)
	if type(row) ~= "table" then return end
	if type(row.layout) ~= "string" or row.layout == "" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) "
		.. "VALUES ('%s','%s','%s','%s',%d) "
		.. "ON CONFLICT(device_id, date, app, layout) DO UPDATE SET "
		.. "count = count + excluded.count;",
		_sql_escape(device_id), _sql_escape(row.date), _sql_escape(row.app),
		_sql_escape(row.layout), math.floor(tonumber(row.count) or 0))
	return sql
end

--- Commits one canonical layout upsert and returns its native receipt.
function M.upsert_layout(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.layout(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts the per-app-day ergonomic record.
---
--- The two streak columns are records and take a MAX; the focus latency sums.
--- A day's longest same-finger run does not get longer by being flushed twice.
--- @param row table { date, app, same_finger_streak_max, same_hand_streak_max,
---        auto_repeat_count, focus_to_first_key_sum_ms, focus_to_first_key_count }
_derived_sql.ergo = function(device_id, row)
	if type(row) ~= "table" then return end
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
	return sql
end

--- Commits one canonical ergo upsert and returns its native receipt.
function M.upsert_ergo(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.ergo(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts one application-to-application transition count for a day.
---
--- The pair is the key, not just the destination: the panel this feeds asks
--- which application the user leaves to reach another, and a count keyed on the
--- destination alone cannot answer that.
--- @param row table { date, app_from, app_to, count }
_derived_sql.switch_to = function(device_id, row)
	if type(row) ~= "table" then return end
	local sql = string.format(
		"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) "
		.. "VALUES ('%s','%s','%s','%s',%d) "
		.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET "
		.. "count = count + excluded.count;",
		_sql_escape(device_id), _sql_escape(row.date),
		_sql_escape(row.app_from), _sql_escape(row.app_to),
		math.floor(tonumber(row.count) or 0))
	return sql
end

--- Commits one canonical switch to upsert and returns its native receipt.
function M.upsert_switch_to(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.switch_to(device_id, row)
	if not sql then return end
	return _exec(sql)
end

--- Upserts the per-app-day typing-session record.
---
--- The durations array is capped by the walk before it gets here, and truncated
--- again in SQL: a day of short sessions would otherwise grow one JSON array
--- without bound, and the dashboard only plots a sample of them.
--- @param row table { date, app, count_total, longest_ms, longest_chars,
---        total_active_ms, durations }
_derived_sql.session = function(device_id, row)
	if type(row) ~= "table" then return end
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
	return sql
end

--- Commits one canonical session upsert and returns its native receipt.
function M.upsert_session(device_id, row)
	if not M.is_available() then return end
	local sql = _derived_sql.session(device_id, row)
	if not sql then return end
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
_derived_sql.ngrams = function(device_id, date, app, ngrams, table_name)
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
					source_parts[#source_parts + 1] = string.format('%s:%d',
					Json.encode(source), math.floor(source_count))
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
		.. number_map_merge_sql("esrc_json") .. ";",
		table.concat(parts, ",")
	)
	return sql
end

--- Commits one canonical ngrams upsert and returns its native receipt.
function M.upsert_ngrams(device_id, date, app, ngrams, table_name)
	if not M.is_available() then return end
	local sql = _derived_sql.ngrams(device_id, date, app, ngrams, table_name)
	if not sql then return end
	return _exec_raw_batch(sql)
end

--- Upserts physical Linux evdev scancodes. This is intentionally distinct
--- from ngram_chars: one key may emit different glyphs by layout/modifier, but
--- the scancode is the invariant physical location used by the heatmap.
--- @param scancodes table { [evdev_code] = count }.
_derived_sql.scancodes = function(device_id, date, app, scancodes)
	if type(scancodes) ~= "table" then return end
	local parts = {}
	for scancode, count in pairs(scancodes) do
		local code = tonumber(scancode)
		if code and code > 0 and type(count) == "number" and count > 0 then
			parts[#parts + 1] = string.format("('%s','%s','%s',%d,%d)",
				_sql_escape(device_id), _sql_escape(date), _sql_escape(app),
				math.floor(code), math.floor(count))
		end
	end
	if #parts == 0 then return "" end
	return "INSERT INTO ngram_scancodes (device_id, date, app, scancode, c) VALUES "
		.. table.concat(parts, ",")
		.. " ON CONFLICT(device_id, date, app, scancode) DO UPDATE SET c = c + excluded.c;"
end

--- Commits one canonical scancodes upsert and returns its native receipt.
function M.upsert_scancodes(device_id, date, app, scancodes)
	if not M.is_available() then return end
	local sql = _derived_sql.scancodes(device_id, date, app, scancodes)
	if not sql then return end
	if sql == "" then return true end
	return _exec(sql)
end

--- The meta key holding one device's still-open sessions and bursts.
--- @param device_id string
--- @return string
local function open_walk_key(device_id)
	return "open_walk:" .. device_id
end

--- Replaces the device's open-walk record inside the flush transaction, so the
--- record and the rows it was cut from commit or roll back together.
--- @param encoded string JSON array produced by the collector (no raw NUL).
_derived_sql.open_walk = function(device_id, encoded)
	assert(type(encoded) == "string" and not encoded:find("[%z\n]"), "Invalid open-walk record")
	return "INSERT INTO meta(key,value) VALUES ('" .. _sql_escape(open_walk_key(device_id)) .. "','"
		.. _sql_escape(encoded) .. "') ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
end

--- Commits one open-walk record outside a flush and returns its native receipt.
function M.upsert_open_walk(device_id, encoded)
	if not M.is_available() then return end
	return _exec(_derived_sql.open_walk(device_id, encoded))
end

--- Reads the open-walk record the last committed flush left for this device.
--- @param device_id string
--- @return string|nil encoded JSON text, nil when no record exists.
--- @return boolean ok False when the read itself failed.
function M.read_open_walk(device_id)
	if not M.is_available() or type(device_id) ~= "string" or device_id == "" then return nil, false end
	local body = _query_output("SELECT value FROM meta WHERE key='" .. _sql_escape(open_walk_key(device_id)) .. "';")
	if body == nil then return nil, false end
	body = body:gsub("\n$", "")
	if body == "" then return nil, true end
	return body, true
end

--- Starts an immutable flush snapshot with one raw/derived transaction.
--- Reservation gaps are harmless; acknowledged IDs and SQL remain stable across
--- data-write retries. Only a unique durable marker resolves a lost COMMIT reply.
--- @param device_id string Device identifier.
--- @param payload table { raw = { typing, hotstrings, shortcuts, switches }, upserts }.
--- @return table|nil Owned logical operation; nil refuses before SQL dispatch.
function M.start_flush(device_id, payload)
	if not M.is_available() or (_flush_owner and not _flush_owner:is_settled()) then return nil end
	assert(type(device_id) == "string" and device_id ~= "")
	assert(type(payload) == "table" and type(payload.raw) == "table" and type(payload.upserts) == "table")
	local Process = require("infra.sqlite_batch_process")
	if not Process.is_available() then return nil end
	local timeout_ms = require("infra.timings").ms("keystats", "sqlite_operation_timeout_ms")
	local function array(values)
		assert(type(values) == "table", "Invalid SQLite flush array")
		local length, entries = #values, 0
		for key, value in pairs(values) do
			assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length
				and type(value) == "table", "Invalid SQLite flush entry")
			entries = entries + 1
		end
		assert(entries == length, "Sparse SQLite flush array")
	end
	array(payload.upserts)
	for _, entry in ipairs(payload.upserts) do
		assert(type(entry.kind) == "string" and type(_derived_sql[entry.kind]) == "function"
			and type(entry.args) == "table", "Invalid SQLite flush intent")
	end
	local path, count = _db_path, 0
	local families = { "typing", "hotstrings", "shortcuts", "switches" }
	for _, name in ipairs(families) do
		array(payload.raw[name])
		count = count + #payload.raw[name]
	end
	count = math.max(1, count)
	local operation, state = {}, { phase = "reservation", child = nil, stopped = false, done = false }
	local owner = "sqlite-flush:" .. tostring(operation)
	local sql, token, first_id

	local function dispatch(phase, body)
		state.phase = phase
		state.read_safe = false
		local called, child = pcall(Process.start, path, body, { owner = owner, timeout_ms = timeout_ms })
		if not called then state.phase = "uncertain"; return end
		state.child = child
		if not child then state.phase = phase .. "_retry" end
	end

	local function finish(committed, reason)
		state.done = true
		operation.result = { committed = committed == true, error = reason }
		-- The receipt has been consumed; no callback or diagnostic retains SQL.
		sql, payload = nil, nil
	end

	local function compose()
		local statements, cursor = {}, first_id
		for _, name in ipairs(families) do
			local rows = payload.raw[name]
			if #rows > 0 then
				statements[#statements + 1] = assert(_raw_sql[name](device_id, rows, cursor))
				cursor = cursor + #rows
			end
		end
		for _, entry in ipairs(payload.upserts) do
			local formatter = assert(_derived_sql[entry.kind])
			local args = { device_id }
			for _, value in ipairs(entry.args) do args[#args + 1] = value end
			local statement = formatter(unpack_values(args))
			assert(type(statement) == "string", "Invalid SQLite flush statement")
			if statement ~= "" then statements[#statements + 1] = statement end
		end
		statements[#statements + 1] = "UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'rev';"
		statements[#statements + 1] = "INSERT INTO meta(key,value) VALUES ('" .. token .. "','committed');"
		return ".output /dev/null\nBEGIN IMMEDIATE;\n" .. table.concat(statements, "\n")
			.. "\nCOMMIT;\n.output stdout\nSELECT 1;\n"
	end

	local function resolve()
		dispatch("resolve", "SELECT COUNT(*) FROM meta WHERE key='" .. token .. "' AND value='committed';")
	end

	local function cleanup()
		state.committed = true
		dispatch("cleanup", "DELETE FROM meta WHERE key='" .. token .. "';")
		if state.phase == "cleanup_retry" then finish(true) end
	end

	function operation:is_settled() return state.done end
	function operation:phase() return state.phase end
	function operation:is_read_safe()
		return (state.done and state.committed == true) or state.read_safe == true
			or state.phase == "reservation_retry" or state.phase == "commit_retry"
			or state.phase == "compose_retry"
	end
	function operation:is_retryable()
		return not state.done and not state.stopped and state.phase:match("_retry$") ~= nil and state.child == nil
	end
	function operation:has_native_operation() return state.child ~= nil end
	function operation:cancel()
		state.stopped = true
		if state.child then state.child:cancel() end
		return self:is_settled()
	end
	function operation:retry()
		if not self:is_retryable() or state.stopped then return false end
		if state.phase == "reservation_retry" then dispatch("reservation", _reservation_sql(count))
		elseif state.phase == "commit_retry" then dispatch("commit", sql)
		elseif state.phase == "resolve_retry" then resolve()
		elseif state.phase == "cleanup_retry" then cleanup()
		elseif state.phase == "compose_retry" then
			local composed, body = pcall(compose)
			if composed then sql = body; dispatch("commit", sql) end
		end
		return true
	end
	function operation:pump()
		if state.done or state.phase == "uncertain" then return state.done end
		if not state.child then
			if state.stopped then
				finish(state.committed, state.committed and nil or "SQLite persistence stopped without a conclusive commit receipt")
			end
			return state.done
		end
		local result = state.child:poll()
		if not result then return false end
		-- poll() admits only exact child/pipe/group/timer settlement. A failed
		-- process can have committed; outcome is resolved on a fresh connection.
		state.child = nil
		if state.phase == "reservation" then
			local digits = result.ok and type(result.output) == "string" and result.output:match("^([1-9]%d*)\n$")
			local value = digits and tonumber(digits)
			if not value or value % 1 ~= 0 or value > EventIdPolicy.MAX_EXACT_LUA_CURSOR - count then
				state.phase = "reservation_retry"
				if state.stopped then finish(false, "SQLite ID reservation was not acknowledged") end
				return state.done
			end
			first_id = value
			token = "linux_flush_commit:" .. string.format("%.0f:%.0f", first_id, count)
			local composed, body = pcall(compose)
			if not composed then
				state.phase = "compose_retry"
				if state.stopped then finish(false, "SQLite flush composition was refused") end
				return state.done
			end
			sql = body
			if state.stopped then finish(false, "SQLite flush stopped before its data transaction")
			else dispatch("commit", sql) end
		elseif state.phase == "commit" then
			if result.ok and result.output == "1\n" then cleanup() else resolve() end
		elseif state.phase == "resolve" then
			if not result.ok or (result.output ~= "0\n" and result.output ~= "1\n") then
				state.phase = "resolve_retry"
				if state.stopped then finish(false, "SQLite COMMIT outcome remains unknown after native retirement") end
			elseif result.output == "1\n" then cleanup()
			elseif state.stopped then state.read_safe = true; finish(false, "SQLite flush was rolled back before shutdown")
			else state.phase = "commit_retry" end
		elseif state.phase == "cleanup" then
			-- Failed marker retirement leaves harmless durable evidence, never a
			-- reason to replay already committed data. Physical retirement is ACK.
			finish(true)
		end
		return state.done
	end

	_flush_owner = operation
	dispatch("reservation", _reservation_sql(count))
	return operation
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
--- @return table|nil One entry per output line, or nil when unavailable/failed.
function M.query_rows(sql)
	if not M.is_available() then return nil end
	if type(sql) ~= "string" or sql == "" then return nil end
	local output = _query_output(sql)
	if output == nil then return nil end
	local lines = {}
	if output ~= "" then
		local framed = output:sub(-1) == "\n" and output or (output .. "\n")
		for line in framed:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	end
	return lines
end

--- Reads one meta key. Used by the migration to resume where it stopped rather
--- than re-reading every row of a year-long history at each daemon start.
--- @param key string
--- @return string|nil The stored value, or nil when absent.
function M.get_meta(key)
	if not M.is_available() or type(key) ~= "string" or key == "" then return nil end
	-- Native raw TEXT output stops at NUL and scalar line framing stops at LF.
	-- Quote just this value so the existing checked scalar path carries one line
	-- while the shared decoder restores every byte, including an empty string.
	local encoded = _query_scalar(string.format("SELECT json_quote(value) FROM meta WHERE key = '%s';", _sql_escape(key)))
	if encoded == nil then return nil end
	local ok, value = pcall(Json.decode, encoded)
	if not ok or type(value) ~= "string" then
		Logger.warn(LOG, "SQLite metadata read returned an invalid JSON string.")
		return nil
	end
	return value
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
