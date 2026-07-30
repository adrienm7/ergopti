--- modules/keylogger/text_migration.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Migration (Linux)
--- DESCRIPTION:
--- Converts events_typing rows that were ALREADY stored before the at-rest
--- setting changed. Enabling encryption wraps the rows written from that point
--- on; this module goes back over the ones written earlier, and reverses them
--- when the setting is turned off.
---
--- WHAT IS HERE AND WHAT IS SHARED:
--- The state machine — cursor discipline, the fail-closed rule, idempotence —
--- lives in _shared/lua/keylogger/text_migration_runner.lua, because macOS runs
--- the identical algorithm and a second copy would be a second place for the
--- rule that protects the user's data to rot. What is here is the Linux half:
--- reading and writing rows through the sqlite3 CLI, and being driven by the
--- daemon's periodic tick.
---
--- WHY IT RUNS IN SLICES:
--- Every value costs one openssl spawn, and the daemon that would pay for it is
--- the same one servicing the keyboard. A single loop over a year of history
--- would freeze typing for minutes. pump() converts ONE bounded batch per call
--- and returns; the daemon's periodic tick calls it four times a second, so the
--- work happens between keystrokes rather than instead of them.
---
--- FEATURES & RATIONALE:
--- 1. The migration's SQL carries the characters the user typed, so it travels
---    to the CLI on standard input through sqlite_writer, exactly like the
---    INSERTs it rewrites. Staging it in /tmp is what once turned the writer
---    into a keystroke leak.
--- 2. Values are read back hex-encoded. The CLI's output separator can occur
---    inside the typed text itself, and a row split on the wrong character would
---    be rewritten with a value the user never typed.
--- 3. Local rows only. The key derives from the machine id, so a row imported
---    from another device could not be decrypted here and must not be encrypted
---    here either — that would lock its owner out of its own data.
--- ==============================================================================

local M = {}

local Logger       = require("logger.shim")
local SqliteWriter = require("modules.keylogger.sqlite_writer")
local TextCipher   = require("modules.keylogger.text_cipher")
local Plan         = require("keylogger.text_migration")
local Runner       = require("keylogger.text_migration_runner")

local LOG = "modules.keylogger.text_migration"




-- ==========================
-- ==========================
-- ======= 1/ Backend =======
-- ==========================
-- ==========================

--- Row access through the sqlite3 CLI. Every statement is composed by the shared
--- plan, so the columns, the device filter and the batch bound cannot drift from
--- the macOS side.
local RealBackend = {}

function RealBackend.available()
	return SqliteWriter.is_available()
end

function RealBackend.count(device_id)
	local rows = SqliteWriter.query_rows(Plan.count_sql(device_id))
	return tonumber(rows and rows[1]) or 0
end

--- Reads one batch, hex-decoding each value (see feature 2).
--- @return table|nil Array of { id, values }, or nil when the read failed.
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
--- @return boolean True on success.
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
	return SqliteWriter.get_meta(Runner.CURSOR_META_KEY)
end

function RealBackend.set_cursor(value)
	return SqliteWriter.set_meta(Runner.CURSOR_META_KEY, value)
end




-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- The runner in force. Rebuilt by _set_backend so a test can drive the whole
--- algorithm over an in-memory table: io.popen never RAISES on a malformed
--- command, it EXECUTES it, so a test that only checked "nothing crashed" would
--- prove nothing at all about this module.
local _runner = Runner.new({
	logger = Logger, log_tag = LOG, cipher = TextCipher, backend = RealBackend,
})

--- Installs a replacement backend (test seam); nil restores the real one.
--- @param replacement table|nil
function M._set_backend(replacement)
	_runner = Runner.new({
		logger = Logger, log_tag = LOG, cipher = TextCipher,
		backend = (type(replacement) == "table") and replacement or RealBackend,
	})
end

--- Starts a migration pass.
--- @param mode      string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
--- @param device_id string The LOCAL device.
--- @return boolean True when a pass is now in flight.
function M.start(mode, device_id)
	return _runner.start(mode, device_id)
end

--- Resumes only a pass a previous run left unfinished.
--- @param mode      string
--- @param device_id string
--- @return boolean True when a pass is now in flight.
function M.resume(mode, device_id)
	return _runner.resume(mode, device_id)
end

--- Converts one bounded batch. Safe to call at any cadence; a no-op when idle.
--- @return boolean True when there is more to do.
function M.pump()
	return _runner.pump()
end

--- Stops the pass; the stored cursor lets a later call resume from there.
function M.cancel()
	_runner.cancel()
end

--- Whether a pass is in flight.
--- @return boolean
function M.is_running()
	return _runner.is_running()
end

--- Snapshot of the pass, for the menu and for diagnostics.
--- @return table
function M.get_progress()
	return _runner.get_progress()
end

return M
