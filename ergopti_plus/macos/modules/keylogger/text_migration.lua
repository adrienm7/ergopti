--- modules/keylogger/text_migration.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Migration (Hammerspoon)
--- DESCRIPTION:
--- macOS counterpart of linux/modules/keylogger/text_migration.lua. Converts
--- events_typing rows that were ALREADY stored before the at-rest setting
--- changed: ticking "Chiffrement" wrapped only the rows written from that point
--- on, so a user with a year of logs enabled a setting that left every one of
--- those rows in clear. Unticking it had the mirror defect.
---
--- WHAT IS HERE AND WHAT IS SHARED:
--- The state machine — cursor discipline, the fail-closed rule, idempotence —
--- lives in _shared/lua/keylogger/text_migration_runner.lua, because Linux runs
--- the identical algorithm and a second copy would be a second place for the
--- rule that protects the user's data to rot. What is here is the macOS half:
--- rows read and written through the SQLite handle sqlite_writer owns, and the
--- slicing that keeps the pass off the typing path.
---
--- WHY IT RUNS IN SLICES:
--- Hammerspoon is single-threaded and every value costs one openssl spawn, so a
--- straight loop over a year of history would block the same run loop that
--- services the keyboard tap — for minutes. Each slice converts ONE bounded
--- batch and schedules the next through adapters/timer_scheduler, which returns
--- control to the run loop between batches.
---
--- FEATURES & RATIONALE:
--- 1. Cancellable. The scheduled handle is kept so the menu can stop a pass; the
---    stored cursor makes that a pause rather than a revert.
--- 2. No direct OS API. The SQLite calls live in sqlite_writer, which already
---    owns the handle, and the scheduling goes through the timer adapter — so
---    this module adds nothing to the driver's direct-API count.
--- 3. Local rows only. The key derives from this Mac's hardware UUID, so a row
---    imported from another device could not be decrypted here and must not be
---    encrypted here either.
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local Scheduler    = require("adapters.timer_scheduler")
local SqliteWriter = require("modules.keylogger.sqlite_writer")
local TextCipher   = require("modules.keylogger.text_cipher")
local Plan         = require("keylogger.text_migration")
local Runner       = require("keylogger.text_migration_runner")

local LOG = "keylogger.text_migration"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Pause between two batches. Long enough that the run loop gets the keyboard
--- tap, the menu and the ingest tick back between slices; short enough that a
--- large history still finishes in one sitting rather than one afternoon.
local SLICE_GAP_SEC = 0.05





-- ==========================
-- ==========================
-- ======= 2/ Backend =======
-- ==========================
-- ==========================

--- Row access through the writer that owns the SQLite handle. Every statement is
--- composed by the shared plan, so the columns, the device filter and the batch
--- bound cannot drift from the Linux side.
local RealBackend = {}

function RealBackend.available()
	return SqliteWriter.get_db() ~= nil
end

function RealBackend.count(device_id)
	return SqliteWriter.count_typing_rows(device_id)
end

function RealBackend.fetch(device_id, after_id, limit)
	return SqliteWriter.fetch_typing_batch(device_id, after_id, limit)
end

function RealBackend.apply(device_id, updates)
	return SqliteWriter.apply_typing_updates(device_id, updates)
end

function RealBackend.get_cursor()
	return SqliteWriter.get_meta(Runner.CURSOR_META_KEY)
end

function RealBackend.set_cursor(value)
	return SqliteWriter.set_meta(Runner.CURSOR_META_KEY, value)
end





-- ==========================
-- ==========================
-- ======= 3/ Slicing =======
-- ==========================
-- ==========================

--- The runner in force. Rebuilt by _set_backend so a test can drive the whole
--- algorithm over an in-memory table.
local _runner = Runner.new({
	logger = Logger, log_tag = LOG, cipher = TextCipher, backend = RealBackend,
})

--- Handle of the scheduled next slice, so a pass can be stopped.
local _slice = nil

--- Runs one batch and schedules the next. Declared as a local BEFORE the closure
--- that reschedules it: in Lua the scope of a local starts after its declaration,
--- so a forward reference inside the closure would resolve to a nil global and
--- the pass would convert exactly one batch and stop.
local run_slice

run_slice = function()
	_slice = nil
	if not _runner.pump() then return end
	_slice = Scheduler.after(SLICE_GAP_SEC, run_slice)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Installs a replacement backend (test seam); nil restores the real one.
--- @param replacement table|nil
function M._set_backend(replacement)
	_runner = Runner.new({
		logger = Logger, log_tag = LOG, cipher = TextCipher,
		backend = (type(replacement) == "table") and replacement or RealBackend,
	})
end

--- Starts a migration pass and schedules its first slice.
--- @param mode      string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
--- @param device_id string|nil The LOCAL device; defaults to the writer's own.
--- @return boolean True when a pass is now in flight.
function M.start(mode, device_id)
	M.cancel()
	if not _runner.start(mode, device_id or SqliteWriter.get_device_id()) then return false end
	_slice = Scheduler.after(SLICE_GAP_SEC, run_slice)
	return true
end

--- Starts the pass matching a posture. Called when the user flips the setting.
--- @param encrypt_enabled boolean The posture now in force.
--- @return boolean True when a pass is now in flight.
function M.start_for_posture(encrypt_enabled)
	return M.start(encrypt_enabled and Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT)
end

--- Resumes only a pass a previous run left unfinished.
--- Used at start-up, where an unconditional start() would re-read every stored
--- row on Macs that never enabled the setting at all.
--- @param encrypt_enabled boolean The posture now in force.
--- @param device_id string|nil The LOCAL device; defaults to the writer's own.
--- @return boolean True when a pass is now in flight.
function M.resume_for_posture(encrypt_enabled, device_id)
	M.cancel()
	local mode = encrypt_enabled and Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT
	if not _runner.resume(mode, device_id or SqliteWriter.get_device_id()) then return false end
	_slice = Scheduler.after(SLICE_GAP_SEC, run_slice)
	return true
end

--- Converts one batch synchronously. The slicing calls it; a test drives it
--- directly rather than waiting on a scheduler.
--- @return boolean True when there is more to do.
function M.pump()
	return _runner.pump()
end

--- Stops the pass. Converted rows stay converted and the stored cursor lets a
--- later call resume from there, so this is a pause and not a revert.
function M.cancel()
	if _slice then
		Scheduler.cancel(_slice)
		_slice = nil
	end
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
