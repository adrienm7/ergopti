--- tests/unit/modules/keystats/storage/test_sqlite_writer_startup_transaction.lua

--- ==============================================================================
--- MODULE: SQLite Writer Startup Transaction Tests
--- DESCRIPTION:
--- Exercise unpublished startup handles, migration failures and exact cleanup
--- ownership with native return codes and exceptions.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Observe a fresh writer while one startup phase can fail.
--- @param schedule table Mutable failure schedule.
--- @param check function Assertions against the writer and observed native state.
local function observe(schedule, check)
	helpers.with_stub_scope({ "infra.logger", "modules.keystats.sqlite_writer", "modules.keystats.text_cipher" }, function()
		local state = { opens = 0, closes = 0, finalizes = 0, published_during_startup = false, logs = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...) state.logs[#state.logs + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		local writer
		local function phase(name)
			if writer.get_db() ~= nil then state.published_during_startup = true end
			if schedule.phase ~= name then return 0 end
			if schedule.failure == "throw" then error("injected " .. name .. " failure") end
			return 1
		end
		local db = {
			exec = function(_, sql)
				if sql:find("PRAGMA journal_mode", 1, true) then return phase("journal") end
				if sql:find("PRAGMA synchronous", 1, true) then return phase("synchronous") end
				if sql:find("PRAGMA encoding", 1, true) then return phase("encoding") end
				if sql:find("INSERT OR IGNORE INTO meta", 1, true) then return phase("meta") end
				if sql:find("ALTER TABLE events_llm", 1, true) then return phase("migration") end
				return 0
			end,
			nrows = function(_, sql)
				if sql == "PRAGMA table_info(events_llm)" then
					phase("columns")
				elseif sql:find("next_event_id", 1, true) then
					phase("counter")
				end
				return function() return nil end
			end,
			prepare = function()
				if phase("device") ~= 0 then return nil end
				state.statement_open = true
				return { bind_values = function() return phase("bind") end,
					step = function() return phase("step") == 0 and 101 or 19 end,
					finalize = function()
						helpers.assert_true(state.statement_open, "statement must be finalized exactly once")
						state.finalizes = state.finalizes + 1
						state.statement_open = false
						return phase("finalize")
					end }
			end,
			close = function()
				helpers.assert_true(not state.closed, "consumed SQLite wrapper cannot be closed again")
				state.closes = state.closes + 1
				if schedule.close == "throw" then error("injected close failure") end
				state.closed = true
				-- The native binding finalizes any remaining statements before close.
				if state.statement_open then state.statement_open = false; state.finalizes = state.finalizes + 1 end
				if schedule.close == "refuse" then return 1 end
				return 0
			end,
			isopen = function()
				if schedule.probe == "throw" then error("injected probe failure") end
				if schedule.probe == "nil" then return nil end
				return not state.closed
			end,
			errmsg = function() return "injected migration refusal" end,
		}
		if schedule.probe == "missing" then db.isopen = nil end
		writer = helpers.load_with_stubs("modules.keystats.sqlite_writer", {
			fs = { attributes = function() return { mode = "file" } end },
			sqlite3 = { OK = 0, ERROR = 1, DONE = 101, ROW = 100,
				open = function() state.opens = state.opens + 1; state.closed = false; return db end },
		})
		writer.init({ paths = { sqlite_path = "/tmp/startup-transaction.sqlite" },
			device_obj = { device_id = "test", name = "Test", os = "darwin", host_signature = "test-host", created_at = "2024-01-01" },
			device_id = "test" })
		check(writer, state, db)
	end)
end

helpers.describe("sqlite-startup-transaction", function()
	helpers.it("publishes the writer only after every startup operation completes", function()
		observe({}, function(writer, state, db)
			helpers.assert_true(writer.open_db())
			helpers.assert_eq(state.published_during_startup, false,
				"migration and device initialization must never observe a writable startup handle")
			helpers.assert_true(rawequal(writer.get_db(), db))
			helpers.assert_true(writer.close_db())
		end)
	end)

	helpers.it("rejects a duplicate open without acquiring or closing another owner", function()
		observe({}, function(writer, state, db)
			helpers.assert_true(writer.open_db())
			helpers.assert_eq(writer.open_db(), false)
			helpers.assert_eq(state.opens, 1)
			helpers.assert_eq(state.closes, 0)
			helpers.assert_true(rawequal(writer.get_db(), db))
			helpers.assert_true(writer.close_db())
		end)
	end)

	for _, phase in ipairs({ "migration", "columns", "counter", "device" }) do
		for _, close in ipairs({ "refuse", "throw" }) do
			helpers.it("retains unpublished " .. phase .. " owner after close " .. close, function()
				local schedule = { phase = phase, failure = "throw", close = close }
				observe(schedule, function(writer, state)
					local ok, result = pcall(writer.open_db)
					helpers.assert_true(ok, "startup exceptions must be contained and diagnosed")
					helpers.assert_eq(result, false)
					helpers.assert_nil(writer.get_db(), "failed startup must never publish a writable handle")
					helpers.assert_eq(state.closes, 1, "failed startup must attempt exact cleanup")
					helpers.assert_eq(writer.open_db(), false, "cleanup debt must block acquisition")
					helpers.assert_eq(state.opens, 1)
					schedule.close = nil
					if close == "throw" then
						helpers.assert_true(writer.close_db(), "confirmed open owner remains retryable")
						helpers.assert_eq(state.closes, 2)
					else
						helpers.assert_eq(writer.close_db(), false, "consumed failure remains fatal debt")
						helpers.assert_eq(state.closes, 1, "consumed wrapper must not be retried")
					end
					helpers.assert_true(table.concat(state.logs, "\n"):find("injected " .. phase, 1, true) ~= nil,
						"primary failure must remain visible alongside cleanup failure")
					schedule.phase = nil
					if close == "throw" then
						helpers.assert_true(writer.open_db(), "retirement releases the acquisition gate")
						helpers.assert_true(writer.close_db())
					else helpers.assert_eq(writer.open_db(), false) end
				end)
			end)
		end
	end

	helpers.it("quarantines a consumed migration database after close refusal", function()
		local schedule = { phase = "migration", failure = "refuse", close = "refuse" }
		observe(schedule, function(writer, state)
			helpers.assert_eq(writer.open_db(), false)
			helpers.assert_nil(writer.get_db())
			helpers.assert_eq(writer.open_db(), false)
			helpers.assert_eq(state.opens, 1, "native close refusal must retain startup ownership")
			schedule.close = nil
			helpers.assert_eq(writer.close_db(), false)
			helpers.assert_eq(state.closes, 1)
		end)
	end)

	for _, phase in ipairs({ "journal", "synchronous", "encoding", "meta", "device", "bind", "step", "finalize" }) do
		helpers.it("sqlite-startup-refusal: rejects native " .. phase .. " refusal", function()
			local schedule = { phase = phase, failure = "refuse" }
			observe(schedule, function(writer, state)
				helpers.assert_eq(writer.open_db(), false)
				helpers.assert_nil(writer.get_db(), "refused startup cannot publish a writer")
				helpers.assert_eq(state.closes, 1)
				local statement_acquired = phase == "bind" or phase == "step" or phase == "finalize"
				helpers.assert_eq(state.finalizes, statement_acquired and 1 or 0)
				helpers.assert_true(#state.logs > 0, "native refusal must be diagnosed")
				schedule.phase = nil
				helpers.assert_true(writer.open_db(), "cleanly retired refusal must permit retry")
				helpers.assert_true(writer.close_db())
			end)
		end)
	end

	for _, phase in ipairs({ "bind", "step", "finalize" }) do
		helpers.it("sqlite-startup-statement: retires statement after " .. phase .. " exception", function()
			observe({ phase = phase, failure = "throw" }, function(writer, state)
				helpers.assert_eq(writer.open_db(), false)
				helpers.assert_nil(writer.get_db())
				helpers.assert_eq(state.finalizes, 1, "statement finalization is attempted exactly once")
				helpers.assert_eq(state.closes, 1)
			end)
		end)
	end

	for _, probe in ipairs({ "throw", "nil", "missing" }) do
		helpers.it("sqlite-close-probe: quarantines an unconfirmed handle after " .. probe, function()
			observe({ phase = "migration", failure = "throw", close = "throw", probe = probe }, function(writer, state)
				helpers.assert_eq(writer.open_db(), false)
				helpers.assert_eq(writer.close_db(), false)
				helpers.assert_eq(writer.open_db(), false)
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1, "unconfirmed owner cannot be retried blindly")
			end)
		end)
	end
end)
