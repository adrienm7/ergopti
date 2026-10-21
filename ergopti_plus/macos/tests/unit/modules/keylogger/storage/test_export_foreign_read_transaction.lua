--- tests/unit/modules/keylogger/storage/test_export_foreign_read_transaction.lua

--- ==============================================================================
--- MODULE: Foreign Ledger Read Transaction Tests
--- DESCRIPTION:
--- A foreign ledger watermark may advance only after seeking to its exact
--- previous position and completing the read and file close successfully.
--- ==============================================================================

local helpers = require("tests.helpers")
local BATCH = "BEGIN TRANSACTION;\nINSERT INTO events VALUES (1);\nCOMMIT;\n"

--- Observe a foreign import over an independently stateful read handle.
--- @param schedule table Selected native failure boundary.
--- @param check function Assertions against the export and observed state.
local function observe(schedule, check)
	helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keylogger.export" }, function()
		local state = { reads = 0, closes = 0, applied = {}, watermark = #BATCH, position = 0, logs = {} }
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, format, ...) state.logs[#state.logs + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.fs_dir"] = { try_entries = function() return { "foreign" }, true end }
		local db = {
			prepare = function() return { bind_values = function() return 0 end,
				step = function() return 101 end, finalize = function() return 0 end } end,
			nrows = function()
				local done = false
				return function()
					if not done then done = true; return { imported_data_sql_size = state.watermark } end
				end
			end,
			exec = function(_, sql)
				if sql:find("UPDATE devices", 1, true) then
					state.watermark = tonumber(sql:match("imported_data_sql_size=(%d+)"))
				else state.applied[#state.applied + 1] = sql end
				return 0
			end,
		}
		local export = helpers.load_with_stubs("modules.keylogger.export", {
			fs = { attributes = function() return { size = #BATCH * 2 } end },
		})
		export.init({ paths = { metrics_dir = "/foreign-read/" }, device_id = "local",
			get_db = function() return db end })
		local original_open = io.open
		io.open = function(path, ...)
			if path:find("device.json", 1, true) then
				return { read = function() return '{"device_id":"foreign"}' end, close = function() return true end }
			end
			if not path:find("data.sql", 1, true) then return original_open(path, ...) end
			if schedule.phase == "open" then
				if schedule.failure == "throw" then error("injected open failure") end
				return nil, "injected open refusal"
			end
			state.position = 0
			return {
				seek = function(_, mode, offset)
					helpers.assert_eq(mode, "set")
					if schedule.phase == "seek" then
						if schedule.failure == "throw" then error("injected seek failure") end
						if schedule.failure == "wrong" then return state.position end
						return nil, "injected seek refusal"
					end
					state.position = offset
					return offset
				end,
				read = function()
					state.reads = state.reads + 1
					if schedule.phase == "read" then
						if schedule.failure == "throw" then error("injected read failure") end
						return nil, "injected read refusal"
					end
					return (BATCH .. BATCH):sub(state.position + 1)
				end,
				close = function()
					state.closes = state.closes + 1
					if schedule.phase == "close" then
						if schedule.failure == "throw" then error("injected close failure") end
						return nil, "injected close refusal"
					end
					return true
				end,
			}
		end
		local ok, err = xpcall(function() check(export, state) end, debug.traceback)
		io.open = original_open
		if not ok then error(err, 0) end
	end)
end

helpers.describe("foreign-ledger-read-transaction", function()
	for _, phase in ipairs({ "open", "seek", "read", "close" }) do
		local failures = phase == "seek" and { "nil", "throw", "wrong" } or { "nil", "throw" }
		for _, failure in ipairs(failures) do
			helpers.it("foreign-ledger-read: preserves watermark after " .. phase .. " " .. failure, function()
				local schedule = { phase = phase, failure = failure }
				observe(schedule, function(export, state)
					local ok, result = pcall(export.sync_foreign_data_sql)
					helpers.assert_true(ok, "read failure must not escape the import boundary")
					helpers.assert_eq(result, {})
					helpers.assert_eq(state.watermark, #BATCH, "failed read must preserve the committed watermark")
					helpers.assert_eq(#state.applied, 0, "unvalidated bytes must never reach SQLite")
					helpers.assert_eq(state.closes, phase == "open" and 0 or 1,
						"every acquired read handle must receive exactly one close attempt")
					if phase == "open" or phase == "seek" then helpers.assert_eq(state.reads, 0) end
					helpers.assert_true(#state.logs > 0, "failed import must explain why it was deferred")
					schedule.phase = nil
					helpers.assert_eq(export.sync_foreign_data_sql(), { "foreign" })
					helpers.assert_eq(state.applied, { BATCH }, "retry must apply only the unread suffix")
					helpers.assert_eq(state.watermark, #BATCH * 2)
				end)
			end)
		end
	end
end)
