--- tests/unit/modules/keylogger/test_data_sql_outbox.lua

--- ==============================================================================
--- MODULE: Regression — local data.sql outbox durability
--- DESCRIPTION:
--- A successful SQLite commit used to advance the JSONL cursor even when the
--- append-only data.sql ledger could not be opened.  db.sqlite is a tmp cache,
--- therefore those events disappeared from the cross-device/canonical record on
--- a later cache loss.  Pin the transaction ordering that makes the payload
--- durable before committing and retries it before a fresh ingest allocates IDs.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local source = helpers.read_driver_source(selector)
	return source
end

helpers.describe("keylogger: data.sql outbox protects committed local events", function()
	helpers.it("back-fills the local outbox meta key for existing SQLite caches", function()
		local source = read_source("local function _read_schema_sql") -- modules/keylogger/sqlite_writer.lua
		helpers.assert_true(
			source:find('{ "local_data_sql_outbox", "" }', 1, true) ~= nil,
			"sqlite_writer.open_db must seed local_data_sql_outbox for upgraded caches"
		)
	end)

	helpers.it("flushes an older outbox before reading more today.log entries", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local flush_pos = assert(source:find("_flush_local_data_sql_outbox(db)", 1, true))
		local read_pos = assert(source:find("Rotation.read_new_entries()", 1, true))
		helpers.assert_true(
			flush_pos < read_pos,
			"a pending canonical batch must be retried before a new JSONL batch is read"
		)
	end)

	helpers.it("persists the exact batch into the outbox before SQLite COMMIT", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local persist_pos = assert(source:find("cannot persist data.sql outbox", 1, true))
		local commit_pos = assert(source:find(
			'_exec_sqlite_or_error(db, "COMMIT;", "cannot commit ingest transaction")',
			persist_pos, true))
		helpers.assert_true(
			persist_pos < commit_pos,
			"the batch text must commit to local_data_sql_outbox before the transaction closes"
		)
	end)

	helpers.it("advances the in-memory cursor only after creating the durable retry record", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local persist_pos = assert(source:find("cannot persist data.sql outbox", 1, true))
		local offset_pos = assert(source:find("Rotation.set_offset(new_offset, Rotation.get_date())", persist_pos, true))
		helpers.assert_true(
			persist_pos < offset_pos,
			"today.log must not be replayed with fresh ids after a failed ledger append"
		)
	end)

	helpers.it("does not delete today.log at rollover while the temporary outbox is pending", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local flush_pos = assert(source:find("day_rollover: local data.sql outbox is not durable", 1, true))
		local rollover_pos = assert(source:find(
			"Rotation.rollover(_paths.data_sql_path, committed_eof)", flush_pos, true))
		helpers.assert_true(
			flush_pos < rollover_pos,
			"day_rollover must retry the pending ledger append before it removes today.log"
		)
	end)
end)

helpers.describe("keylogger: SQLite transaction refusal preserves the ingest batch", function()
	local MODULE_KEYS = {
		"adapters.file_system",
		"infra.timings",
		"keylogger.metrics",
		"modules.keylogger.aggregator",
		"modules.keylogger.export",
		"modules.keylogger.log_manager",
		"modules.keylogger.rotation",
		"modules.keylogger.sqlite_writer",
	}

	local function run_refused_transaction(failure)
		local absent = {}
		local saved = {}
		for _, key in ipairs(MODULE_KEYS) do
			local current = package.loaded[key]
			saved[key] = current == nil and absent or current
		end

		local sqlite = _G.hs.sqlite3
		local observations = {
			builds = 0,
			commits = 0,
			offset_writes = 0,
			reads = 0,
			resets = 0,
			rollbacks = 0,
		}
		local next_event_id = 10
		local db = {
			errmsg = function() return "database is locked" end,
			exec = function(_self, sql)
				if sql == "ROLLBACK;" then
					observations.rollbacks = observations.rollbacks + 1
					return sqlite.OK
				end
				if failure == "commit" and sql == "COMMIT;" then
					observations.commits = observations.commits + 1
					return sqlite.BUSY or 5
				end
				if failure == "begin" and sql == "BEGIN TRANSACTION;" then
					return sqlite.BUSY or 5
				end
				if failure == "offset" and sql:find("today_log_offset", 1, true) then
					return sqlite.BUSY or 5
				end
				return sqlite.OK
			end,
			nrows = function()
				return function() return nil end
			end,
		}

		package.loaded["adapters.file_system"] = {
			create_if_absent = function() return true, "created" end,
			read = function() return nil end,
			write = function() return true end,
		}
		package.loaded["infra.timings"] = {
			ms = function() return 5000 end,
			sec = function() return 1 end,
		}
		package.loaded["keylogger.metrics"] = {}
		package.loaded["modules.keylogger.aggregator"] = {
			flush = function() return true end,
			get_ngram_ctx = function() return {} end,
			reset_batch = function() observations.resets = observations.resets + 1 end,
			reset_ngram_ctx = function() end,
			set_ngram_ctx = function() end,
			walk_system_event = function() end,
		}
		package.loaded["modules.keylogger.export"] = {
			sync_foreign_data_sql = function() return {} end,
		}
		package.loaded["modules.keylogger.rotation"] = {
			get_date = function() return "2026-08-25" end,
			get_offset = function() return 0 end,
			read_new_entries = function()
				observations.reads = observations.reads + 1
				return { { entry = { type = "system_event" } } }, 123, "ok"
			end,
			set_offset = function() observations.offset_writes = observations.offset_writes + 1 end,
		}
		package.loaded["modules.keylogger.sqlite_writer"] = {
			build_inserts = function()
				observations.builds = observations.builds + 1
				next_event_id = next_event_id + 1
				return { "INSERT OR IGNORE INTO events_system VALUES (1);" }
			end,
			get_db = function() return db end,
			get_next_event_id = function() return next_event_id end,
			persist_next_event_id = function() return failure ~= "event_id" end,
			set_next_event_id = function(value) next_event_id = value end,
		}

		package.loaded["modules.keylogger.log_manager"] = nil
		local manager = helpers.load_with_stubs("modules.keylogger.log_manager")
		manager.ingest_once()
		manager.ingest_once()
		observations.next_event_id = next_event_id

		for _, key in ipairs(MODULE_KEYS) do
			package.loaded[key] = saved[key] == absent and nil or saved[key]
		end
		return observations
	end

	helpers.it("rolls back a non-OK COMMIT and re-reads the same journal tail", function()
		local observed = run_refused_transaction("commit")

		helpers.assert_eq(observed.commits, 2,
			"each retry must reach the native COMMIT refusal")
		helpers.assert_eq(observed.offset_writes, 0,
			"a refused COMMIT must not advance the today.log cursor")
		helpers.assert_eq(observed.reads, 2,
			"the unchanged cursor must make the next ingest re-read the same batch")
		helpers.assert_eq(observed.builds, 2,
			"the retained journal batch must be rebuilt on the retry")
		helpers.assert_eq(observed.next_event_id, 10,
			"each rollback must restore the event-id allocator before retry")
		helpers.assert_eq(observed.resets, 2,
			"each refused transaction must discard its aggregate batch")
		helpers.assert_eq(observed.rollbacks, 4,
			"each attempt needs one defensive rollback and one checked failure rollback")
	end)

	helpers.it("applies the same rollback boundary to BEGIN and metadata siblings", function()
		for _, failure in ipairs({ "begin", "offset", "event_id" }) do
			local observed = run_refused_transaction(failure)

			helpers.assert_eq(observed.offset_writes, 0,
				failure .. " refusal must not advance the today.log cursor")
			helpers.assert_eq(observed.reads, 2,
				failure .. " refusal must leave the journal batch available for retry")
			helpers.assert_eq(observed.next_event_id, 10,
				failure .. " refusal must restore the event-id allocator")
			helpers.assert_eq(observed.resets, 2,
				failure .. " refusal must discard the aggregate batch")
			helpers.assert_eq(observed.rollbacks, 4,
				failure .. " refusal must run the checked rollback path")
		end
	end)
end)
