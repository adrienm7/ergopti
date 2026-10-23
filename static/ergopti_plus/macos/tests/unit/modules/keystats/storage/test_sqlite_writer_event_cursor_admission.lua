--- tests/unit/modules/keystats/storage/test_sqlite_writer_event_cursor_admission.lua

--- ==============================================================================
--- MODULE: SQLite writer persisted event cursor admission
--- DESCRIPTION:
--- open_db restored meta.next_event_id with `tonumber(value) or 1`. A malformed
--- cursor silently restarted ids at 1, and every new event whose id already
--- existed was then dropped by INSERT OR IGNORE without a trace; a fractional
--- or exponent value ("1.5", "1e20") was admitted and later raised "number has
--- no integer representation" in the insert builders, outside the ingest pcall
--- (event-cursor-admission-2026-10-21). Only a positive decimal integer within
--- Lua's integer range is admitted now; anything else refuses the open, as on
--- Linux, so the JSONL ledger keeps the events for a later recovery.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Opens a fresh writer whose meta table holds `cursor`.
--- @param cursor string Persisted next_event_id text.
--- @return boolean opened, table writer, table logs
local function open_with_cursor(cursor)
	local opened, writer, logs
	helpers.with_stub_scope({ "infra.logger", "modules.keystats.sqlite_writer", "modules.keystats.text_cipher" }, function()
		logs = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...) logs[#logs + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		local db = {
			exec = function() return 0 end,
			nrows = function(_, sql)
				local rows = {}
				if sql:find("next_event_id", 1, true) then rows = { { value = cursor } } end
				local index = 0
				return function() index = index + 1; return rows[index] end
			end,
			prepare = function()
				return { bind_values = function() return 0 end, step = function() return 101 end,
					finalize = function() return 0 end }
			end,
			close = function() return 0 end,
			isopen = function() return true end,
			errmsg = function() return "" end,
		}
		writer = helpers.load_with_stubs("modules.keystats.sqlite_writer", {
			fs = { attributes = function() return { mode = "file" } end },
			sqlite3 = { OK = 0, ERROR = 1, DONE = 101, ROW = 100, open = function() return db end },
		})
		writer.init({ paths = { sqlite_path = "/tmp/cursor.sqlite" },
			device_obj = { device_id = "test", name = "Test", os = "darwin", host_signature = "h", created_at = "2024-01-01" },
			device_id = "test" })
		opened = writer.open_db()
	end)
	return opened, writer, logs
end


helpers.describe("sqlite_writer admits only a valid persisted event cursor (event-cursor-admission-2026-10-21)", function()
	for _, cursor in ipairs({ "garbage", "", "0", "-3", "1.5", "1e20", "0x10", " 7", "99999999999999999999" }) do
		helpers.it("refuses the open for cursor " .. string.format("%q", cursor), function()
			local opened, writer, logs = open_with_cursor(cursor)
			helpers.assert_eq(opened, false, "a malformed cursor must not restart or corrupt event ids")
			helpers.assert_nil(writer.get_db())
			helpers.assert_true(#logs >= 1, "the refusal must be logged")
		end)
	end

	helpers.it("restores a valid cursor exactly", function()
		local opened, writer = open_with_cursor("9007199254740993")
		helpers.assert_eq(opened, true)
		helpers.assert_eq(writer.get_next_event_id(), 9007199254740993)
		helpers.assert_eq(math.type(writer.get_next_event_id()), "integer")
	end)
end)
