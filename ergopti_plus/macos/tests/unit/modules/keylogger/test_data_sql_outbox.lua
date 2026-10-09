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
local Fixture = require("tests.support.data_sql_outbox_fixture")

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
	helpers.it("rolls back a non-OK COMMIT and re-reads the same journal tail", function()
		local observed = Fixture.run_refused_transaction("commit")

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
			local observed = Fixture.run_refused_transaction(failure)

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
