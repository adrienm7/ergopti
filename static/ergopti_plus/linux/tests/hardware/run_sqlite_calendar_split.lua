--- tests/hardware/run_sqlite_calendar_split.lua
--- Real libc DST/calendar and SQLite public collectors with a declared Lua
--- wall-clock input seam. No SQLite/process/database/provider mocks or hardware claims.
local uv = require("luv")
local ffi = require("ffi")
require("compat.utf8").install()
ffi.cdef("void tzset(void);")
-- POSIX rules require no installed timezone database. libc does all calendar
-- normalization; only the instant supplied to Lua's no-argument clock is owned.
assert(uv.os_setenv("TZ", "CET-1CEST,M3.5.0/2,M10.5.0/3"))
ffi.C.tzset()
local native_date, native_time = os.date, os.time
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-calendar-split-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local fixtures = {
	{ name = "25-hour DST end late evening", year = 2026, month = 10, day = 25, hour = 23, min = 30, previous = "2026-10-24" },
	{ name = "midnight after 23-hour DST start", year = 2026, month = 3, day = 30, hour = 0, min = 30, previous = "2026-03-29" },
	{ name = "DST end early morning", year = 2026, month = 10, day = 25, hour = 0, min = 30, previous = "2026-10-24" },
	{ name = "ordinary day", year = 2026, month = 10, day = 24, hour = 12, min = 30, previous = "2026-10-23" },
	{ name = "midnight after DST end", year = 2026, month = 10, day = 26, hour = 0, min = 5, previous = "2026-10-25" },
	{ name = "leap year boundary", year = 2024, month = 3, day = 1, hour = 0, min = 5, previous = "2024-02-29" },
	{ name = "year boundary", year = 2027, month = 1, day = 1, hour = 0, min = 5, previous = "2026-12-31" },
	{ name = "month boundary", year = 2026, month = 5, day = 1, hour = 23, min = 30, previous = "2026-04-30" },
}
local checks, failures = 0, 0
local function count_today(payload, token)
	local count = 0
	for _, grams in pairs(payload.today) do count = count + (grams.c[token] and grams.c[token].c or 0) end
	return count
end
for i, fixture in ipairs(fixtures) do
	checks = checks + 1
	local instant = native_time({ year = fixture.year, month = fixture.month, day = fixture.day, hour = fixture.hour, min = fixture.min, sec = 0 })
	os.date = function(format, timestamp) return native_date(format, timestamp or instant) end
	os.time = function(date) return date and native_time(date) or instant end
	local path = root .. "/owned-" .. i .. ".sqlite"
	Writer.close_db()
	local ok, err = xpcall(function()
		Keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" })
		assert(Keylogger.is_enabled() and Writer.is_available())
		Keylogger.record_synthetic_output("owned-calendar", "aa", "other", 1000)
		Keylogger.flush()
		local rows = assert(Writer.query_rows("SELECT date,app,c FROM ngram_chars WHERE token='a';"))
		assert(#rows == 1 and rows[1]:match("|2$"))
		assert(Writer.upsert_ngrams("owned-history", fixture.previous, "owned-calendar", { h = { c = 7 } }, "ngram_chars"))
		local before = table.concat(assert(Writer.query_rows("SELECT date,app,token,c FROM ngram_chars ORDER BY date,token;")), "\n")
		local revision = Writer.get_revision()
		for _, payload in ipairs({ Reader.read_range_split_today(path), Keylogger.get_range_payload() }) do
			assert(payload.historical.c.a == nil, "today's persisted row duplicated into historical")
			assert(payload.historical.c.h and payload.historical.c.h.c == 7, "previous calendar day's persisted row omitted")
			assert(count_today(payload, "a") == 2 and count_today(payload, "h") == 0)
		end
		assert(Writer.get_revision() == revision)
		assert(table.concat(assert(Writer.query_rows("SELECT date,app,token,c FROM ngram_chars ORDER BY date,token;")), "\n") == before)
	end, debug.traceback)
	os.date, os.time = native_date, native_time
	if ok then print("PASS " .. fixture.name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. fixture.name .. ": " .. tostring(err) .. "\n")
	end
end
Writer.close_db()
local function remove_owned(path)
	local stat = assert(uv.fs_lstat(path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
assert(checks == 8, "the native calendar split matrix must execute all eight controls")
print(string.format("Native SQLite calendar split with owned clock input: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
