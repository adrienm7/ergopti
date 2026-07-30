--- modules/keylogger/text_migration.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Migration (Linux)
--- DESCRIPTION:
--- Converts events_typing rows that were ALREADY stored before the at-rest
--- setting changed. Enabling encryption wraps the rows written from that point
--- on; this module goes back over the ones written earlier, and reverses them
--- when the setting is turned off.
---
--- WHY IT RUNS IN SLICES:
--- Every value costs one openssl spawn, and the daemon that would pay for it is
--- the same one servicing the keyboard. A single loop over a year of history
--- would freeze typing for minutes. pump() therefore converts ONE bounded batch
--- per call and returns; the daemon's periodic tick calls it four times a second,
--- so the work happens between keystrokes rather than instead of them.
---
--- FEATURES & RATIONALE:
--- 1. Restart-safe without a lock file. The cursor lives in the database's own
---    meta table and advances only after the batch it covers has committed, so an
---    interrupted run resumes where it stopped. If the stored cursor is missing
---    or belongs to the other direction, the pass simply restarts from zero and
---    re-scans — slower, never wrong, because a value already in the target state
---    is skipped rather than converted twice.
--- 2. Fail CLOSED, in both directions. If encryption cannot run, the pass stops
---    with the remaining rows still in clear rather than storing an empty column;
---    if DECRYPTION cannot run, it stops rather than replacing an envelope with
---    the empty string the cipher returns when it has no key. Losing the data the
---    migration exists to protect would be worse than leaving it half-converted,
---    and a half-converted table is legible: the envelope carries a marker, so
---    every row says which state it is in.
--- 3. Local rows only. The key derives from the machine id, so a row imported
---    from another device could not be decrypted here and must not be encrypted
---    here either — that would lock its owner out of its own data.
--- 4. One openssl invocation per value, never a second key derivation: the key is
---    derived once and cached inside text_cipher.
--- 5. The database access sits behind a replaceable backend. io.popen never
---    RAISES on a malformed command, it EXECUTES it, so a test that only checked
---    "nothing crashed" would prove nothing here; driving the algorithm through a
---    value-level backend is what lets a test assert that a round trip really
---    returns the original bytes.
--- ==============================================================================

local M = {}

local Logger       = require("logger.shim")
local SqliteWriter = require("modules.keylogger.sqlite_writer")
local TextCipher   = require("modules.keylogger.text_cipher")
local TextCrypto   = require("keylogger.text_crypto")
local Plan         = require("keylogger.text_migration")

local LOG = "modules.keylogger.text_migration"




-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- meta key holding "<mode>:<cursor>" so a restart resumes instead of re-reading
--- every row. Stored in the database rather than beside it: a sidecar file could
--- describe a database that has since been replaced.
local CURSOR_META_KEY = "text_migration_cursor"

--- Separator inside that value. Neither field can contain it.
local CURSOR_SEPARATOR = ":"

--- Rows converted between two progress lines. Low enough to show that a long
--- migration is alive, high enough not to flood the log.
local PROGRESS_LOG_INTERVAL_ROWS = 500




-- ========================
-- ========================
-- ======= 2/ State =======
-- ========================
-- ========================

-- Direction of the pass in flight, or nil when idle.
local _mode = nil

-- The device whose rows this pass may touch.
local _device_id = nil

-- Highest row id already covered. Rows at or below it are in the target state.
local _cursor = 0

-- Rows read and rows actually rewritten, for the progress report.
local _scanned = 0
local _converted = 0

-- Rows this pass may touch in total, for the progress fraction.
local _total = 0

-- Rows converted at the last progress line.
local _last_logged = 0

-- Replaceable data access (see feature 5). nil means "use the real database".
local _backend = nil




-- ==========================
-- ==========================
-- ======= 3/ Backend =======
-- ==========================
-- ==========================

--- The real backend: every statement is composed by the shared plan and run
--- through sqlite_writer, which feeds SQL to the CLI on standard input. The
--- migration's SQL carries the characters the user typed, so it may no more
--- travel through a file in /tmp than the writer's own INSERTs may.
local RealBackend = {}

function RealBackend.available()
	return SqliteWriter.is_available()
end

function RealBackend.count(device_id)
	local rows = SqliteWriter.query_rows(Plan.count_sql(device_id))
	return tonumber(rows and rows[1]) or 0
end

--- Reads one batch. The values come back hex-encoded because the CLI's output
--- separator can occur inside the typed text itself, and a row split on the
--- wrong character would be rewritten with a value the user never typed.
function RealBackend.fetch(device_id, after_id, limit)
	local lines = SqliteWriter.query_rows(
		Plan.select_batch_sql(device_id, after_id, limit, { hex = true }))
	if lines == nil then return nil end
	local rows = {}
	for _, line in ipairs(lines) do
		local row_id, values = Plan.parse_hex_row(line)
		if row_id then rows[#rows + 1] = { id = row_id, values = values } end
	end
	return rows
end

--- Commits a batch of rewrites as ONE transaction: either every row of it is
--- rewritten or none is, so an interruption can never leave a row with one
--- column converted and the other still in its old state.
function RealBackend.apply(device_id, updates)
	if #updates == 0 then return true end
	local statements = {}
	for _, update in ipairs(updates) do
		local sql = Plan.update_row_sql(device_id, update.id, update.assignments)
		if not sql then return false end
		statements[#statements + 1] = sql
	end
	return SqliteWriter.exec_sql("BEGIN;\n" .. table.concat(statements, "\n") .. "\nCOMMIT;\n")
end

function RealBackend.get_cursor()
	return SqliteWriter.get_meta(CURSOR_META_KEY)
end

function RealBackend.set_cursor(value)
	return SqliteWriter.set_meta(CURSOR_META_KEY, value)
end

--- Returns the backend in force.
local function backend()
	return _backend or RealBackend
end

--- Installs a replacement backend (test seam); nil restores the real one.
--- @param replacement table|nil
function M._set_backend(replacement)
	_backend = (type(replacement) == "table") and replacement or nil
end




-- ======================================
-- ======================================
-- ======= 4/ Cursor Persistence ========
-- ======================================
-- ======================================

--- Reads the resume point for a direction.
--- @param mode string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
--- @return number The row id to resume after; 0 when there is nothing to resume.
local function read_cursor(mode)
	local stored = backend().get_cursor()
	if type(stored) ~= "string" then return 0 end
	local stored_mode, stored_cursor = stored:match("^([^" .. CURSOR_SEPARATOR .. "]+)"
		.. CURSOR_SEPARATOR .. "(%d+)$")
	-- A cursor from the OTHER direction says nothing about this one: those rows
	-- are converted, just not the way this pass wants them.
	if stored_mode ~= mode then return 0 end
	return tonumber(stored_cursor) or 0
end

--- Persists the resume point. Called only after the batch it covers committed,
--- so a crash between the two costs a re-scan and never a skipped row.
--- @param mode   string
--- @param cursor number
local function write_cursor(mode, cursor)
	backend().set_cursor(mode .. CURSOR_SEPARATOR .. tostring(math.floor(cursor)))
end




-- =============================
-- =============================
-- ======= 5/ Conversion =======
-- =============================
-- =============================

--- Stops the pass, leaving every already-converted row converted.
--- @param reason string Why it stopped, for the log.
--- @return nil
local function abort(reason)
	Logger.error(LOG, "At-rest migration stopped after %d row(s): %s. "
		.. "Remaining rows are unchanged and still readable.", _converted, reason)
	_mode = nil
	return nil
end

--- Marks the pass finished.
--- @return nil
local function finish()
	write_cursor(_mode, _cursor)
	Logger.success(LOG, "At-rest migration finished: %d row(s) converted, %d scanned.",
		_converted, _scanned)
	_mode = nil
	return nil
end

--- Converts ONE column value, or returns nil when it cannot be converted.
--- Both directions are checked against what SUCCESS looks like rather than
--- against an error code: encrypt() hands back the plaintext when the toggle is
--- off, and decrypt() hands back the empty string when the key is missing — so
--- "it returned something" is not evidence that anything was converted.
--- @param value  string The stored value.
--- @param row_id number The events_typing row id.
--- @param column string The column name.
--- @return string|nil The converted value, or nil on failure.
local function convert_value(value, row_id, column)
	local iv_event_id = Plan.iv_event_id(row_id, column)
	if not iv_event_id then return nil end

	if _mode == Plan.MODE_ENCRYPT then
		local wrapped = TextCipher.encrypt(_device_id, iv_event_id, value)
		if type(wrapped) ~= "string" or not TextCrypto.is_encrypted(wrapped) then return nil end
		return wrapped
	end

	local plain = TextCipher.decrypt(value)
	-- An envelope never wraps an empty value (encrypt skips those), so an empty
	-- result means the decryption failed. Writing it would erase the row.
	if type(plain) ~= "string" or plain == "" then return nil end
	return plain
end

--- Lists the rewrites one row needs.
--- @param row_id number
--- @param values table  { [column] = stored value }.
--- @return table|nil assignments, boolean failed.
local function plan_row(row_id, values)
	local assignments = {}
	for _, spec in ipairs(Plan.COLUMNS) do
		local value = values[spec.name]
		if Plan.needs_conversion(_mode, value, TextCrypto.is_encrypted) then
			local converted = convert_value(value, row_id, spec.name)
			if converted == nil then return nil, true end
			assignments[#assignments + 1] = { name = spec.name, value = converted }
		end
	end
	return assignments, false
end




-- =============================
-- =============================
-- ======= 6/ Public API =======
-- =============================
-- =============================

--- Starts a migration pass.
--- @param mode      string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
--- @param device_id string The LOCAL device; foreign rows are never touched.
--- @return boolean True when a pass is now in flight.
function M.start(mode, device_id)
	if mode ~= Plan.MODE_ENCRYPT and mode ~= Plan.MODE_DECRYPT then
		Logger.error(LOG, "start(): unknown migration mode '%s'.", tostring(mode))
		return false
	end
	if type(device_id) ~= "string" or device_id == "" then
		Logger.error(LOG, "start(): a device id is required — refusing to touch every device's rows.")
		return false
	end
	if not backend().available() then
		Logger.warn(LOG, "No database open — nothing to migrate.")
		return false
	end

	_mode        = mode
	_device_id   = device_id
	_cursor      = read_cursor(mode)
	_scanned     = 0
	_converted   = 0
	_last_logged = 0
	_total       = backend().count(device_id)

	Logger.start(LOG, "At-rest migration (%s) over %d row(s), resuming after id %d…",
		mode, _total, _cursor)
	return true
end

--- Resumes a pass a previous run left unfinished, and ONLY that.
--- Called at start-up, where an unconditional start() would re-read every row of
--- a year-long history on machines that never enabled the setting at all.
--- @param mode      string
--- @param device_id string
--- @return boolean True when a pass is now in flight.
function M.resume(mode, device_id)
	if not backend().available() then return false end
	local stored = backend().get_cursor()
	if type(stored) ~= "string" or not stored:match("^" .. mode .. CURSOR_SEPARATOR .. "%d+$") then
		return false
	end
	return M.start(mode, device_id)
end

--- Converts one bounded batch. Safe to call at any cadence; a no-op when idle.
--- @return table|nil The progress snapshot, or nil once the pass has ended.
function M.pump()
	if not _mode then return nil end

	local rows = backend().fetch(_device_id, _cursor, Plan.DEFAULT_BATCH_SIZE)
	if rows == nil then return abort("the batch could not be read") end
	if #rows == 0 then return finish() end

	local updates = {}
	local batch_cursor = _cursor
	for _, row in ipairs(rows) do
		_scanned = _scanned + 1
		if row.id > batch_cursor then batch_cursor = row.id end
		local assignments, failed = plan_row(row.id, row.values)
		if failed then
			return abort(string.format("row %d could not be converted", row.id))
		end
		if #assignments > 0 then
			updates[#updates + 1] = { id = row.id, assignments = assignments }
		end
	end

	if not backend().apply(_device_id, updates) then
		return abort("the batch could not be written")
	end
	_converted = _converted + #updates

	-- Only now: the cursor must never claim ground the write did not cover.
	_cursor = batch_cursor
	write_cursor(_mode, _cursor)

	if _converted - _last_logged >= PROGRESS_LOG_INTERVAL_ROWS then
		_last_logged = _converted
		Logger.info(LOG, "At-rest migration: %d/%d row(s) scanned, %d converted.",
			_scanned, _total, _converted)
	end

	-- A short batch means the cursor has passed the last row.
	if #rows < Plan.DEFAULT_BATCH_SIZE then return finish() end
	return M.get_progress()
end

--- Stops the pass. Already-converted rows stay converted, and the stored cursor
--- lets a later call resume from there, so this is a pause and not a revert.
function M.cancel()
	if not _mode then return end
	Logger.info(LOG, "At-rest migration cancelled after %d converted row(s).", _converted)
	_mode = nil
end

--- Whether a pass is in flight.
--- @return boolean
function M.is_running()
	return _mode ~= nil
end

--- Snapshot of the pass, for the menu and for diagnostics.
--- @return table
function M.get_progress()
	return {
		running   = _mode ~= nil,
		mode      = _mode,
		scanned   = _scanned,
		converted = _converted,
		total     = _total,
		cursor    = _cursor,
	}
end

return M
