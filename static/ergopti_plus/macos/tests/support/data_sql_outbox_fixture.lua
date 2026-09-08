--- tests/support/data_sql_outbox_fixture.lua

--- ==============================================================================
--- MODULE: Data SQL Outbox Transaction Fixture
--- DESCRIPTION:
--- Exercises two refused ingest attempts against one real log manager and one
--- shared transaction state, exposing observations without persistent native state.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE_KEYS = {
	"adapters.file_system",
	"infra.timings",
	"keylogger.metrics",
	"modules.keylogger.aggregator",
	"modules.keylogger.export",
	"modules.keylogger.log_manager",
	"modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer",
	"infra.logger",
	"adapters.timer_scheduler",
	"modules.keylogger.timestamp",
}

--- Runs both ingest retries inside one isolated module and native scope.
--- @param failure string Refused transaction boundary.
--- @return table observations
local function run_refused_transaction(failure)
	return helpers.with_stub_scope(MODULE_KEYS, function()
		local sqlite = helpers.load_with_stubs("hs").sqlite3
		package.loaded["infra.logger"] = helpers.make_logger_stub()
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

		return observations
	end)
end

return { run_refused_transaction = run_refused_transaction }
