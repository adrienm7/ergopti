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

local function read_source(relative_path)
	local fh = assert(io.open(helpers.driver_root() .. relative_path, "r"))
	local source = fh:read("*a")
	fh:close()
	return source
end

helpers.describe("keylogger: data.sql outbox protects committed local events", function()
	helpers.it("back-fills the local outbox meta key for existing SQLite caches", function()
		local source = read_source("modules/keylogger/sqlite_writer.lua")
		helpers.assert_true(
			source:find('{ "local_data_sql_outbox", "" }', 1, true) ~= nil,
			"sqlite_writer.open_db must seed local_data_sql_outbox for upgraded caches"
		)
	end)

	helpers.it("flushes an older outbox before reading more today.log entries", function()
		local source = read_source("modules/keylogger/log_manager.lua")
		local flush_pos = assert(source:find("_flush_local_data_sql_outbox(db)", 1, true))
		local read_pos = assert(source:find("Rotation.read_new_entries()", 1, true))
		helpers.assert_true(
			flush_pos < read_pos,
			"a pending canonical batch must be retried before a new JSONL batch is read"
		)
	end)

	helpers.it("persists the exact batch into the outbox before SQLite COMMIT", function()
		local source = read_source("modules/keylogger/log_manager.lua")
		local persist_pos = assert(source:find("cannot persist data.sql outbox", 1, true))
		local commit_pos = assert(source:find('db:exec("COMMIT;")', persist_pos, true))
		helpers.assert_true(
			persist_pos < commit_pos,
			"the batch text must commit to local_data_sql_outbox before the transaction closes"
		)
	end)

	helpers.it("advances the in-memory cursor only after creating the durable retry record", function()
		local source = read_source("modules/keylogger/log_manager.lua")
		local persist_pos = assert(source:find("cannot persist data.sql outbox", 1, true))
		local offset_pos = assert(source:find("Rotation.set_offset(new_offset, Rotation.get_date())", persist_pos, true))
		helpers.assert_true(
			persist_pos < offset_pos,
			"today.log must not be replayed with fresh ids after a failed ledger append"
		)
	end)

	helpers.it("does not delete today.log at rollover while the temporary outbox is pending", function()
		local source = read_source("modules/keylogger/log_manager.lua")
		local flush_pos = assert(source:find("day_rollover: local data.sql outbox is not durable", 1, true))
		local rollover_pos = assert(source:find("Rotation.rollover(_paths.data_sql_path)", flush_pos, true))
		helpers.assert_true(
			flush_pos < rollover_pos,
			"day_rollover must retry the pending ledger append before it removes today.log"
		)
	end)
end)
