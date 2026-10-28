--- modules/keystats/text_migration.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Migration (Hammerspoon)
--- DESCRIPTION:
--- macOS counterpart of linux/modules/keystats/text_migration.lua. Converts
--- events_typing rows that were ALREADY stored before the at-rest setting
--- changed: ticking "Chiffrement" wrapped only the rows written from that point
--- on, so a user with a year of logs enabled a setting that left every one of
--- those rows in clear. Unticking it had the mirror defect.
---
--- WHAT IS HERE AND WHAT IS SHARED:
--- The state machine — cursor discipline, the fail-closed rule, idempotence —
--- lives in _shared/lua/keystats/text_migration_runner.lua, because Linux runs
--- the identical algorithm and a second copy would be a second place for the
--- rule that protects the user's data to rot. What is here is the macOS half:
--- rows read and written through the SQLite handle sqlite_writer owns, and the
--- scheduler port that keeps the pass off the typing path (the public surface
--- and the slicing live in _shared/lua/keystats/text_migration_driver.lua).
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

local Logger       = require("infra.logger")
local Scheduler    = require("adapters.timer_scheduler")
local SqliteWriter = require("modules.keystats.sqlite_writer")
local TextCipher   = require("modules.keystats.text_cipher")
local Driver       = require("keystats.text_migration_driver")
local Runner       = require("keystats.text_migration_runner")

local LOG = "keystats.text_migration"





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





-- ===============================
-- ===============================
-- ======= 3/ Public API =========
-- ===============================
-- ===============================

--- Sliced here: the scheduler port arms each pass's next slice, and the device
--- defaults to the one the writer owns. The seam that swaps the backend lets a
--- test drive the algorithm over an in-memory table.
local module, err = Driver.new({
	logger = Logger, log_tag = LOG, cipher = TextCipher, backend = RealBackend,
	scheduler = { after = Scheduler.after, cancel = Scheduler.cancel, gap_sec = SLICE_GAP_SEC },
	device_id = function() return SqliteWriter.get_device_id() end,
})
assert(module, err)

return module
