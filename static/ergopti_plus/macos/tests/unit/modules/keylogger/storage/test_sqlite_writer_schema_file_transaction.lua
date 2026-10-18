--- tests/unit/modules/keylogger/storage/test_sqlite_writer_schema_file_transaction.lua

--- ==============================================================================
--- MODULE: SQLite Schema File Transaction Tests
--- DESCRIPTION:
--- Fresh-cache schema reads close every acquired stream, reject native read or
--- close refusals and retain ambiguous consumed-file cleanup debt without retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Observe fresh-cache startup while the canonical schema stream can fail.
--- @param schedule table Mutable native file failure schedule.
--- @param check function Assertions against the writer and observed owners.
local function observe(schedule, check)
	helpers.with_stub_scope({ "infra.logger", "modules.keylogger.sqlite_writer", "modules.keylogger.text_cipher" }, function()
		local state = { opens = 0, reads = 0, closes = 0, db_opens = 0, db_closes = 0, errors = {} }
		state.file_exists = schedule.existing_partial == true
		state.meta_exists = schedule.existing_partial == true
		state.schema_applied = false
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...) state.errors[#state.errors + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		local writer = helpers.load_with_stubs("modules.keylogger.sqlite_writer", {
			fs = { attributes = function() return state.file_exists and { mode = "file" } or nil end },
			sqlite3 = { OK = 0, DONE = 101, ROW = 100,
				open = function()
					state.db_opens = state.db_opens + 1
					state.file_exists = true
					return { exec = function(_, sql)
						if sql:find("CREATE TABLE schema_fixture", 1, true) then
							state.schema_applied, state.meta_exists = true, true
						end
						if sql:find("ALTER TABLE events_llm", 1, true) and not state.schema_applied then return 1 end
						return 0
					end,
						nrows = function(_, sql)
							local row
							if sql:find("sqlite_master", 1, true) and state.meta_exists then row = { name = "meta" } end
							if sql:find("key='schema_version'", 1, true) and state.schema_applied then row = { value = "1" } end
							return function() local result = row; row = nil; return result end
						end,
						errmsg = function() return "missing canonical table" end,
						prepare = function() return { bind_values = function() return 0 end,
							step = function() return 101 end, finalize = function() return 0 end } end,
						close = function() state.db_closes = state.db_closes + 1; return 0 end }
				end },
		})
		writer.init({ paths = { sqlite_path = "/tmp/schema-transaction.sqlite" },
			device_obj = { device_id = "test", name = "Test", os = "darwin",
				host_signature = "test-host", created_at = "2024-01-01" }, device_id = "test" })
		local original_open = io.open
		io.open = function(path, ...)
			if not path:match("/schema%.sql$") then return original_open(path, ...) end
			state.opens = state.opens + 1
			if schedule.phase == "open" then
				if schedule.failure == "throw" then error("injected schema open exception") end
				return nil, "injected schema open refusal"
			end
			local consumed = false
			return { read = function()
				state.reads = state.reads + 1
				if schedule.phase == "read" then
					if schedule.failure == "throw" then error("injected schema read exception") end
					return nil, "injected schema read refusal"
				end
				return "CREATE TABLE schema_fixture (id INTEGER);"
			end,
			close = function()
				helpers.assert_eq(consumed, false, "an ambiguous file close must never be retried")
				consumed = true
				state.closes = state.closes + 1
				if schedule.phase == "close" then
					if schedule.failure == "throw" then error("injected schema close exception") end
					return nil, "injected schema close refusal"
				end
				return true
			end }
		end
		local ok, err = xpcall(function() check(writer, state) end, debug.traceback)
		io.open = original_open
		if not ok then error(err, 0) end
	end)
end

helpers.describe("sqlite-schema-file-transaction", function()
	helpers.it("sqlite-bootstrap-completion: reuses a completed schema on reopen", function()
		observe({}, function(writer, state)
			helpers.assert_true(writer.open_db())
			helpers.assert_true(writer.close_db())
			helpers.assert_true(writer.open_db())
			helpers.assert_eq(state.reads, 1, "completed schema must not be reapplied on reopen")
			helpers.assert_true(writer.close_db())
		end)
	end)

	helpers.it("sqlite-bootstrap-completion: repairs a previous process's partial schema", function()
		observe({ existing_partial = true }, function(writer, state)
			helpers.assert_true(writer.open_db(), "a file with meta but no schema version is an unfinished bootstrap")
			helpers.assert_eq(state.reads, 1, "unfinished bootstrap must reapply the canonical schema")
			helpers.assert_true(writer.close_db())
		end)
	end)

	for _, phase in ipairs({ "open", "read", "close" }) do
		for _, failure in ipairs({ "nil", "throw" }) do
			helpers.it("sqlite-schema-file: rejects " .. phase .. " " .. failure, function()
				local schedule = { phase = phase, failure = failure }
				observe(schedule, function(writer, state)
					helpers.assert_eq(writer.open_db(), false)
					helpers.assert_nil(writer.get_db())
					helpers.assert_eq(state.db_closes, 1)
					helpers.assert_eq(state.closes, phase == "open" and 0 or 1)
					helpers.assert_true(#state.errors > 0, "schema failure must be diagnosed")
					schedule.phase = nil
					if phase == "close" then
						helpers.assert_eq(writer.open_db(), false, "ambiguous file ownership blocks startup")
						helpers.assert_eq(writer.close_db(), false, "database retirement cannot clear file debt")
						helpers.assert_eq(state.db_opens, 1)
						helpers.assert_eq(state.opens, 1)
						helpers.assert_eq(state.closes, 1)
					else
						helpers.assert_true(writer.open_db(), "a fully retired failed read can be retried")
						helpers.assert_true(writer.close_db())
					end
				end)
			end)
		end
	end
end)
