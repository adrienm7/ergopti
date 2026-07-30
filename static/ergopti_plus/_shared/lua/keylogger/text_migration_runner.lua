--- _shared/lua/keylogger/text_migration_runner.lua

--- ==============================================================================
--- MODULE: Typed-Text Migration Runner (shared)
--- DESCRIPTION:
--- The state machine that walks events_typing in batches and converts each row
--- between clear text and the at-rest envelope. Linux and macOS both instantiate
--- it; only the database access and the scheduling differ between them, and both
--- are injected.
---
--- WHY IT IS SHARED:
--- The hard parts of this pass — where the cursor may advance, what counts as a
--- successful conversion, when to stop rather than write — are identical on both
--- drivers and are exactly the parts that are easy to get subtly wrong. Two
--- copies would be two places for the fail-closed rule to rot, and the one that
--- rotted would lose a user's data silently.
---
--- FEATURES & RATIONALE:
--- 1. The cursor advances only AFTER the batch it covers has been written. A
---    cursor that ran ahead of the write would skip those rows forever, which is
---    the one failure mode that looks like success.
--- 2. Fail CLOSED in both directions, checked against what SUCCESS looks like
---    rather than against an error code: encrypt() hands back the plaintext when
---    the toggle is off, and decrypt() hands back the empty string when the key
---    is missing, so "it returned something" proves nothing.
--- 3. Idempotent, therefore restart-safe. needs_conversion() skips a value
---    already in the target state, so a re-run after an interruption converges
---    whether or not the stored cursor survived.
--- 4. Injected backend. The runner never opens a database and never spawns
---    anything, so a test can drive the whole algorithm over an in-memory table
---    and assert that a round trip returns the original bytes.
--- ==============================================================================

local M = {}

local Plan       = require("keylogger.text_migration")
local TextCrypto = require("keylogger.text_crypto")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- meta key holding "<mode>:<cursor>" so a restart resumes instead of re-reading
--- every row. Stored in the database rather than beside it: a sidecar file could
--- describe a database that has since been replaced.
M.CURSOR_META_KEY = "text_migration_cursor"

--- Separator inside that value. Neither field can contain it.
local CURSOR_SEPARATOR = ":"

--- Rows converted between two progress lines. Low enough to show that a long
--- migration is alive, high enough not to flood the log.
local PROGRESS_LOG_INTERVAL_ROWS = 500





-- ===========================
-- ===========================
-- ======= 2/ Instance =======
-- ===========================
-- ===========================

--- Creates a runner.
--- @param deps table Must contain:
---   logger  table    The driver's logger (error/warn/info/start/success).
---   log_tag string   Tag passed as the logger's first argument.
---   cipher  table    The driver's text_cipher (encrypt/decrypt).
---   backend table    available/count/fetch/apply/get_cursor/set_cursor.
--- @return table|nil The runner, or nil when a dependency is missing.
function M.new(deps)
	if type(deps) ~= "table"
		or type(deps.logger)  ~= "table"
		or type(deps.log_tag) ~= "string"
		or type(deps.cipher)  ~= "table"
		or type(deps.backend) ~= "table" then
		return nil
	end

	local Logger  = deps.logger
	local LOG     = deps.log_tag
	local Cipher  = deps.cipher
	local backend = deps.backend

	-- Declared before every closure that reads them: in Lua the scope of a local
	-- starts AFTER its declaration, so a closure written above one of these would
	-- capture a nil GLOBAL of the same name and silently never see the state.
	local mode = nil
	local device_id = nil
	local cursor = 0
	local scanned = 0
	local converted = 0
	local total = 0
	local last_logged = 0

	local runner = {}

	--- Reads the resume point for a direction.
	local function read_cursor(for_mode)
		local stored = backend.get_cursor()
		if type(stored) ~= "string" then return 0 end
		local stored_mode, stored_cursor = stored:match("^([^" .. CURSOR_SEPARATOR .. "]+)"
			.. CURSOR_SEPARATOR .. "(%d+)$")
		-- A cursor from the OTHER direction says nothing about this one: those
		-- rows are converted, just not the way this pass wants them.
		if stored_mode ~= for_mode then return 0 end
		return tonumber(stored_cursor) or 0
	end

	--- Persists the resume point. Called only after the batch it covers was
	--- written, so a crash between the two costs a re-scan and never a skipped row.
	local function write_cursor()
		backend.set_cursor(mode .. CURSOR_SEPARATOR .. tostring(math.floor(cursor)))
	end

	--- Stops the pass, leaving every already-converted row converted.
	local function abort(reason)
		Logger.error(LOG, "At-rest migration stopped after %d row(s): %s. "
			.. "Remaining rows are unchanged and still readable.", converted, reason)
		mode = nil
		return false
	end

	--- Marks the pass finished.
	local function finish()
		write_cursor()
		Logger.success(LOG, "At-rest migration finished: %d row(s) converted, %d scanned.",
			converted, scanned)
		mode = nil
		return false
	end

	--- Converts ONE column value, or returns nil when it cannot be converted.
	local function convert_value(value, row_id, column)
		local iv_event_id = Plan.iv_event_id(row_id, column)
		if not iv_event_id then return nil end

		if mode == Plan.MODE_ENCRYPT then
			local wrapped = Cipher.encrypt(device_id, iv_event_id, value)
			-- encrypt() returns the plaintext untouched when the toggle is off, so
			-- only the envelope marker proves anything actually happened.
			if type(wrapped) ~= "string" or not TextCrypto.is_encrypted(wrapped) then return nil end
			return wrapped
		end

		local plain = Cipher.decrypt(value)
		-- An envelope never wraps an empty value (encrypt skips those), so an empty
		-- result means the decryption failed. Writing it would erase the row.
		if type(plain) ~= "string" or plain == "" then return nil end
		return plain
	end

	--- Lists the rewrites one row needs.
	--- @return table|nil assignments, boolean failed.
	local function plan_row(row_id, values)
		local assignments = {}
		for _, spec in ipairs(Plan.COLUMNS) do
			local value = values[spec.name]
			if Plan.needs_conversion(mode, value, TextCrypto.is_encrypted) then
				local result = convert_value(value, row_id, spec.name)
				if result == nil then return nil, true end
				assignments[#assignments + 1] = { name = spec.name, value = result }
			end
		end
		return assignments, false
	end

	--- Starts a pass.
	--- @param wanted_mode string Plan.MODE_ENCRYPT or Plan.MODE_DECRYPT.
	--- @param owner       string The LOCAL device; foreign rows are never touched.
	--- @return boolean True when a pass is now in flight.
	function runner.start(wanted_mode, owner)
		if wanted_mode ~= Plan.MODE_ENCRYPT and wanted_mode ~= Plan.MODE_DECRYPT then
			Logger.error(LOG, "start(): unknown migration mode '%s'.", tostring(wanted_mode))
			return false
		end
		if type(owner) ~= "string" or owner == "" then
			Logger.error(LOG, "start(): a device id is required — refusing to touch every device's rows.")
			return false
		end
		if not backend.available() then
			Logger.warn(LOG, "No database open — nothing to migrate.")
			return false
		end

		mode        = wanted_mode
		device_id   = owner
		cursor      = read_cursor(wanted_mode)
		scanned     = 0
		converted   = 0
		last_logged = 0
		total       = backend.count(owner)

		Logger.start(LOG, "At-rest migration (%s) over %d row(s), resuming after id %d…",
			wanted_mode, total, cursor)
		return true
	end

	--- Resumes a pass a previous run left unfinished, and ONLY that.
	--- Used at start-up, where an unconditional start() would re-read every row of
	--- a year-long history on machines that never enabled the setting at all.
	--- @return boolean True when a pass is now in flight.
	function runner.resume(wanted_mode, owner)
		if not backend.available() then return false end
		local stored = backend.get_cursor()
		if type(stored) ~= "string"
			or not stored:match("^" .. wanted_mode .. CURSOR_SEPARATOR .. "%d+$") then
			return false
		end
		return runner.start(wanted_mode, owner)
	end

	--- Converts one bounded batch. A no-op when no pass is in flight.
	--- @return boolean True when there is more to do.
	function runner.pump()
		if not mode then return false end

		local rows = backend.fetch(device_id, cursor, Plan.DEFAULT_BATCH_SIZE)
		if rows == nil then return abort("the batch could not be read") end
		if #rows == 0 then return finish() end

		local updates = {}
		local batch_cursor = cursor
		for _, row in ipairs(rows) do
			scanned = scanned + 1
			if row.id > batch_cursor then batch_cursor = row.id end
			local assignments, failed = plan_row(row.id, row.values)
			if failed then
				return abort(string.format("row %d could not be converted", row.id))
			end
			if #assignments > 0 then
				updates[#updates + 1] = { id = row.id, assignments = assignments }
			end
		end

		if not backend.apply(device_id, updates) then
			return abort("the batch could not be written")
		end
		converted = converted + #updates

		-- Only now: the cursor must never claim ground the write did not cover.
		cursor = batch_cursor
		write_cursor()

		if converted - last_logged >= PROGRESS_LOG_INTERVAL_ROWS then
			last_logged = converted
			Logger.info(LOG, "At-rest migration: %d/%d row(s) scanned, %d converted.",
				scanned, total, converted)
		end

		-- A short batch means the cursor has passed the last row.
		if #rows < Plan.DEFAULT_BATCH_SIZE then return finish() end
		return true
	end

	--- Stops the pass. Already-converted rows stay converted and the stored cursor
	--- lets a later call resume from there, so this is a pause and not a revert.
	function runner.cancel()
		if not mode then return end
		Logger.info(LOG, "At-rest migration cancelled after %d converted row(s).", converted)
		mode = nil
	end

	--- Whether a pass is in flight.
	--- @return boolean
	function runner.is_running()
		return mode ~= nil
	end

	--- Snapshot of the pass, for the menu and for diagnostics.
	--- @return table
	function runner.get_progress()
		return {
			running   = mode ~= nil,
			mode      = mode,
			scanned   = scanned,
			converted = converted,
			total     = total,
			cursor    = cursor,
		}
	end

	return runner
end

return M
