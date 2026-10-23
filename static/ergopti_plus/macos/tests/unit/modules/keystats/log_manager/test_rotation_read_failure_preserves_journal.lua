--- tests/unit/modules/keystats/log_manager/test_rotation_read_failure_preserves_journal.lua

--- ==============================================================================
--- MODULE: Keystats Journal Read-Failure Rollover Tests
--- DESCRIPTION:
--- Wires the real rotation and log-manager modules to a non-empty virtual
--- today.log. A read failure must remain distinguishable from committed EOF so
--- day rollover cannot delete the only durable copy of un-ingested events.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ End-to-End Harness ========
-- ======================================
-- ======================================

local JOURNAL_SIZE = 128

local STUBBED_MODULES = {
	"modules.keystats.sqlite_writer",
	"modules.keystats.aggregator",
	"modules.keystats.rotation",
	"modules.keystats.export",
	"keystats.metrics",
	"adapters.file_system",
	"adapters.ledger_append",
	"adapters.timer_scheduler",
	"modules.keystats.log_manager",
	"modules.keystats.timestamp",
	"modules.keystats.physical_accounting_mode",
	"modules.keystats.physical_wire",
	"keystats.physical_release",
	"infra.logger",
}

local function fake_writer(on_write, on_close)
	return {
		closed = false,
		setvbuf = function(_, mode) return mode == "no" end,
		write = function(self, text)
			if on_write then on_write(text) end
			return self
		end,
		flush = function() return true end,
		close = function(self)
			assert(not self.closed); self.closed = true
			if on_close then on_close() end
			return true
		end,
	}
end

local function make_reader(failure_mode)
	local position = 0
	return {
		seek = function(_, whence, offset)
			if whence == "end" then
				position = JOURNAL_SIZE
			elseif whence == "set" then
				position = offset or 0
			end
			return position
		end,
		read = function()
			if failure_mode == "read" then return nil, "input/output error", 5 end
			return nil
		end,
		close = function()
			if failure_mode == "close" then return nil, "close failed", 5 end
			return true
		end,
	}
end

local function make_state()
	return {
		LOG_DIR               = "/virtual/keystats/metrics",
		buffer_events         = {},
		buffer_text           = "",
		rich_chunks           = {},
		session_mouse_clicks  = 0,
		session_mouse_scrolls = 0,
		mouse_distance_px     = 0,
		last_flush_time       = 0,
		last_time             = 0,
		pending_keyup         = {},
		today_idx             = {},
		manifest              = {},
	}
end

local function run_rollover_case(failure_mode, exercise_resume)
	-- Keep every newly loaded transitive module and every stub publication local
	-- to this fixture, including the real manager/rotation ownership pair.
	local saved_modules = {}
	for name, value in pairs(package.loaded) do saved_modules[name] = value end
	local real_open, real_remove, real_hs = io.open, os.remove, rawget(_G, "hs")
	local observed = { journal_removes = 0, journal_opens = 0, journal_closes = 0,
		marker_writes = 0, reset_calls = 0, read_calls = 0, journal_writes = {},
		owner_preparations = 0, reset_transactions = {} }
	local paths, active_db, manager, scheduled, attempt
	local journal_present, storage_refused = true, true
	local streams, timers = {}, {}
	local function writer(on_write, on_close)
		local stream = fake_writer(on_write, on_close)
		streams[#streams + 1] = stream
		return stream
	end
	local function outbox_rows()
		local emitted = false
		return function()
			if emitted then return nil end
			emitted = true
			return { value = "" }
		end
	end
	local transaction
	local db = {
		nrows = function(_, sql)
			assert(sql == "SELECT value FROM meta WHERE key='local_data_sql_outbox'")
			if transaction then transaction[#transaction + 1] = sql end
			return outbox_rows()
		end,
		exec = function(_, sql)
			if sql == "BEGIN TRANSACTION;" then
				assert(transaction == nil); transaction = { sql }
			elseif sql == "COMMIT;" then
				assert(transaction and #transaction == 5)
				transaction[#transaction + 1] = sql
				observed.reset_transactions[#observed.reset_transactions + 1] = transaction
				transaction = nil
			else
				local expected = {
					[3] = "UPDATE meta SET value='0' WHERE key='today_log_offset';",
					[4] = "UPDATE meta SET value='" .. attempt.date .. "' WHERE key='today_log_date';",
					[5] = "UPDATE meta SET value='{}' WHERE key='ngram_ctx_json';",
				}
				assert(transaction and sql == expected[#transaction + 1], "unexpected reset SQL")
				transaction[#transaction + 1] = sql
			end
			return 0 -- hs.sqlite3.OK is numeric; nil is never a commit acknowledgement.
		end,
		errmsg = function() return "unexpected rollover SQL" end,
	}
	local ok, result_or_error = xpcall(function()
		for _, name in ipairs(STUBBED_MODULES) do package.loaded[name] = nil end
		local errors, logger = {}, helpers.make_logger_stub()
		logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				assert(delay == 0 and type(callback) == "function" and scheduled == nil)
				scheduled = { timer = {}, committed = true, callback = callback }
				return scheduled, true
			end,
			cancel = function(handle)
				assert(handle == scheduled and handle.timer ~= nil)
				handle.timer, handle.committed, scheduled = nil, false, nil
				return true
			end,
			now = os.time,
		}
		-- A typed unit owner, not a second implementation of the disk protocol.
		package.loaded["adapters.ledger_append"] = {
			recover = function(...)
				assert(select("#", ...) == 3)
				local ledger, batch, journal = ...
				assert(paths and ledger == paths.data_sql_path and batch == ""
					and journal == paths.today_log_path and active_db == nil and attempt == nil)
				return true -- Explicitly empty durable volume admits JSONL-only startup.
			end,
			flush = function(...)
				assert(select("#", ...) == 4)
				local ledger, batch, clear, origin = ...
				assert(ledger == paths.data_sql_path and batch == ""
					and type(clear) == "function" and type(origin) == "function")
				return attempt == nil or attempt.settled == true
			end,
			rollover = function(...)
				assert(select("#", ...) == 7)
				local ledger, journal, offset, previous, next_date, reset, origin = ...
				assert(ledger == paths.data_sql_path and journal == paths.today_log_path)
				assert(offset == JOURNAL_SIZE and previous == "2099-06-30")
				assert(type(next_date) == "string" and next_date:match("^%d%d%d%d%-%d%d%-%d%d$"))
				assert(type(reset) == "function" and type(origin) == "function")
				if not attempt then
					attempt = { date = next_date, completion = {} }
					observed.owner_preparations = observed.owner_preparations + 1
				else assert(not attempt.settled and attempt.date == next_date) end
				local removed, ack = pcall(os.remove, journal)
				if not removed or ack ~= true then return false end
				observed.marker_writes = observed.marker_writes + 1
				local commits = #observed.reset_transactions
				assert(reset(next_date, attempt.completion) == true,
					"rollover owner requires literal true after the checked reset COMMIT")
				assert(#observed.reset_transactions == commits + 1)
				attempt.settled = true
				return true
			end,
			cleanup = function() return true end,
		}
		io.open = function(path, mode)
			if paths and path == paths.today_log_path and mode == "a" then
				observed.journal_opens = observed.journal_opens + 1
				journal_present = true
				return writer(function(text)
					observed.journal_writes[#observed.journal_writes + 1] = text
				end, function() observed.journal_closes = observed.journal_closes + 1 end)
			end
			if paths and path == paths.today_log_path and mode == "r" then
				if not journal_present then return nil, "no such file", 2 end
				observed.read_calls = observed.read_calls + 1
				return make_reader(failure_mode)
			end
			if paths and path == paths.data_sql_path and mode == "w" then return writer() end
			assert(mode ~= "a" and mode ~= "w", "unexpected virtual write path")
			return real_open(path, mode)
		end
		os.remove = function(path)
			assert(paths and path == paths.today_log_path, "unexpected virtual delete path")
			observed.journal_removes = observed.journal_removes + 1
			if storage_refused and failure_mode == "remove_throw" then error("injected remove failure") end
			if storage_refused and failure_mode == "remove" then return nil, "permission denied", 13 end
			journal_present = false
			return true
		end
		package.loaded["modules.keystats.sqlite_writer"] = {
			init = function(deps) paths = deps.paths end,
			open_db = function() return false end,
			close_db = function() active_db = nil; return true end,
			get_db = function() return active_db end,
		}
		package.loaded["modules.keystats.aggregator"] = {
			init = function() end,
			reset_ngram_ctx = function() observed.reset_calls = observed.reset_calls + 1 end,
		}
		package.loaded["modules.keystats.export"] = {
			init = function() end,
			get_native_app_category = function() return "other" end,
			get_device_short_id = function() return "abcd" end,
			get_sqlite_path = function() return "/virtual/cache.sqlite" end,
			get_db_rev = function() return 0 end,
			sync_foreign_data_sql = function() return {} end,
		}
		package.loaded["keystats.metrics"] = {}
		package.loaded["adapters.file_system"] = {
			write = function() return true end,
			create_if_absent = function() return true, "created" end,
			read = function() return nil end,
		}
		local rotation = helpers.load_with_stubs("modules.keystats.rotation")
		manager = helpers.load_with_stubs("modules.keystats.log_manager", {
			execute = function(command)
				if command:find("ioreg", 1, true) then return "TEST-HOST-ROLLOVER" end
				return ""
			end,
			fs = { attributes = function() return nil end,
				dir = function() return function() return nil end end, mkdir = function() return true end },
			timer = { absoluteTime = function() return 1000000000 end,
				secondsSinceEpoch = os.time, new = function(_, callback)
				local handle = { running = false, callback = callback }
				function handle:start() self.running = true; return self end
				function handle:stop() self.running = false; return self end
				timers[#timers + 1] = handle
				return handle
			end },
		})
		helpers.assert_eq(manager.init(make_state()), true,
			"the rollover harness must initialize before exercising the read boundary: " .. table.concat(errors, " | "))
		assert(paths and rotation.is_initialized() and observed.journal_opens == 1)
		-- Explicit phase transition: fallback startup is complete; rollover now
		-- owns a live recording cache and the same manager-resolved journal path.
		rotation.set_offset(failure_mode == "read" and 0 or JOURNAL_SIZE, "2099-06-30")
		active_db = db
		local status_before
		if failure_mode == nil then local _, _, status = rotation.read_new_entries(); status_before = status end
		local rolled = manager.day_rollover()
		local append_result
		if failure_mode == "remove" or failure_mode == "remove_throw" then
			append_result = rotation.append_log({ type = "typing", timestamp = "2099-06-30 23:59:59.999", text = "x" })
		end
		local _, offset_after, status_after = rotation.read_new_entries()
		local result = { append_result = append_result, date_before_append = rotation.get_date(),
			journal_removes = observed.journal_removes, journal_opens = observed.journal_opens,
			journal_closes = observed.journal_closes, marker_writes = observed.marker_writes,
			offset_before_append = rotation.get_offset(), reset_calls = observed.reset_calls,
			read_calls = observed.read_calls, rollover_result = rolled, status_before = status_before,
			status_after = status_after, offset_after = offset_after }
		if exercise_resume then
			assert(failure_mode == "remove")
			result.queued_accept = manager.append_log({ type = "typing",
				timestamp = "2099-06-30 23:59:59.999", text = "queued" })
			result.blocked_ingest = manager.ingest_once()
			result.blocked_writes, result.blocked_opens = #observed.journal_writes, observed.journal_opens
			result.blocked_resets, result.blocked_offset = observed.reset_calls, rotation.get_offset()
			storage_refused = false
			result.resumed = manager.day_rollover()
			assert(scheduled and scheduled.committed == true)
			local retained = scheduled
			retained.timer, retained.committed, scheduled = nil, false, nil
			retained.callback() -- One settled scheduler delivery drains the real manager FIFO.
			result.queued_writes, result.resumed_opens = #observed.journal_writes, observed.journal_opens
			result.queued_entry = assert(require("hs.json").decode(observed.journal_writes[1]))
			result.preparations, result.reset_transactions = observed.owner_preparations, observed.reset_transactions
			result.resumed_resets, result.resumed_markers = observed.reset_calls, observed.marker_writes
		end
		return result
	end, debug.traceback)
	local cleanup_error
	local function cleanup(action)
		local cleaned, detail = xpcall(action, debug.traceback)
		if not cleaned and cleanup_error == nil then cleanup_error = detail end
	end
	cleanup(function() if manager then assert(manager.stop({ process_exit = true }) == true) end end)
	if ok and exercise_resume then result_or_error.writes_after_stop = #observed.journal_writes end
	for _, stream in ipairs(streams) do
		cleanup(function() if not stream.closed then assert(stream:close() == true) end end)
	end
	for _, handle in ipairs(timers) do
		cleanup(function() if handle.running then handle:stop() end; assert(handle.running == false) end)
	end
	cleanup(function()
		if scheduled then assert(package.loaded["adapters.timer_scheduler"].cancel(scheduled) == true) end
		assert(scheduled == nil and active_db == nil and transaction == nil)
	end)
	io.open, os.remove, _G.hs = real_open, real_remove, real_hs
	for name in pairs(package.loaded) do if saved_modules[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved_modules) do package.loaded[name] = value end
	if not ok then error(result_or_error, 0) end
	if cleanup_error then error(cleanup_error, 0) end
	return result_or_error
end





-- ==========================================
-- ==========================================
-- ======= 2/ Committed EOF Ownership =======
-- ==========================================
-- ==========================================

helpers.describe("keystats rollover requires committed EOF", function()
	helpers.it("preserves a non-empty journal when its read fails", function()
		local result = run_rollover_case("read")
		helpers.assert_true(result.read_calls >= 1,
			"the failure must come from attempting to read the non-empty journal")
		helpers.assert_eq(result.journal_removes, 0,
			"read failure must never reach Rotation.rollover's delete boundary")
		helpers.assert_eq(result.reset_calls, 0,
			"read failure must preserve the aggregate resumption context")
		helpers.assert_eq(result.rollover_result, false,
			"day_rollover must report a retryable failure when EOF was not committed")
		helpers.assert_eq(result.status_after, "failed",
			"rotation must expose read failure separately from EOF")
		helpers.assert_eq(result.offset_after, 0,
			"a failed read must preserve the last committed byte offset")
	end)

	helpers.it("preserves a fully read journal when close does not commit", function()
		local result = run_rollover_case("close")
		helpers.assert_eq(result.journal_removes, 0,
			"close failure must invalidate EOF before the delete boundary")
		helpers.assert_eq(result.reset_calls, 0,
			"close failure must preserve the aggregate resumption context")
		helpers.assert_eq(result.rollover_result, false,
			"day_rollover must report failure until the reader closes successfully")
		helpers.assert_eq(result.status_after, "failed",
			"rotation must expose close failure separately from committed EOF")
	end)

	helpers.it("allows rollover only after a successful close at exact EOF", function()
		local result = run_rollover_case(nil)
		helpers.assert_eq(result.status_before, "eof",
			"an exact end offset with a successful close must commit EOF explicitly")
		helpers.assert_eq(result.journal_removes, 1,
			"a committed EOF may cross the rollover delete boundary exactly once")
		helpers.assert_eq(result.reset_calls, 1,
			"successful rollover must reset aggregate context exactly once")
		helpers.assert_eq(result.rollover_result, true,
			"day_rollover must report success after committed EOF")
	end)

	helpers.it("publishes no rollover state when today.log deletion is refused", function()
		for _, failure_mode in ipairs({ "remove", "remove_throw" }) do
			local result = run_rollover_case(failure_mode)
			helpers.assert_eq(result.journal_removes, 1,
				failure_mode .. " must attempt the exact journal deletion once")
			helpers.assert_eq(result.rollover_result, false,
				failure_mode .. " must keep rollover retryable")
			helpers.assert_eq(result.offset_before_append, JOURNAL_SIZE,
				failure_mode .. " must preserve the committed journal offset")
			helpers.assert_eq(result.date_before_append, "2099-06-30",
				failure_mode .. " must preserve the journal date")
			helpers.assert_eq(result.reset_calls, 0,
				failure_mode .. " must preserve aggregate resumption context")
			helpers.assert_eq(result.marker_writes, 0,
				failure_mode .. " must not publish a durable rollover marker")
			helpers.assert_eq(result.journal_closes, 1,
				failure_mode .. " must close the old append handle before retirement")
			helpers.assert_eq(result.journal_opens, 1,
				failure_mode .. " must not reopen the journal while rollover is fenced")
			helpers.assert_eq(result.append_result, false,
				failure_mode .. " must fence the append owner while rollover is pending")
		end
	end)

	helpers.it("retains the manager FIFO until the same rollover attempt settles", function()
		local result = run_rollover_case("remove", true)
		helpers.assert_eq(result.queued_accept, true, "manager must own the queued event while storage is refused")
		helpers.assert_eq(result.blocked_ingest, false, "pending rollover must fence ingest before FIFO persistence")
		helpers.assert_eq(result.blocked_writes, 0, "a fenced FIFO head must not reach the journal")
		helpers.assert_eq(result.blocked_opens, 1, "blocked persistence must not admit a replacement writer")
		helpers.assert_eq(result.blocked_resets, 0, "refused retirement must preserve aggregate context")
		helpers.assert_eq(result.blocked_offset, JOURNAL_SIZE, "refused retirement must preserve the consumed cursor")
		helpers.assert_eq(result.resumed, true, "the retained attempt must settle when storage recovers")
		helpers.assert_eq(result.preparations, 1, "retry must resume the same prepared rollover")
		helpers.assert_eq(result.resumed_opens, 2, "settlement must admit exactly one new append handle")
		helpers.assert_eq(result.queued_writes, 1, "the retained FIFO entry must persist exactly once")
		helpers.assert_eq(result.writes_after_stop, 1, "final cleanup must not replay an already consumed FIFO head")
		helpers.assert_eq(result.queued_entry.text, "queued", "the exact queued entry must survive refusal")
		helpers.assert_eq(result.resumed_markers, 1, "one settled rollover must publish one marker")
		helpers.assert_eq(result.resumed_resets, 1, "aggregate context must reset once after settlement")
		helpers.assert_eq(#result.reset_transactions, 1, "only one checked reset transaction may commit")
		helpers.assert_eq(result.reset_transactions[1][1], "BEGIN TRANSACTION;")
		helpers.assert_eq(result.reset_transactions[1][5], "UPDATE meta SET value='{}' WHERE key='ngram_ctx_json';")
		helpers.assert_eq(result.reset_transactions[1][6], "COMMIT;")
	end)
end)
