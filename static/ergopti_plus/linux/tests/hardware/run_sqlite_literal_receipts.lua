--- tests/hardware/run_sqlite_literal_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite Literal Receipts
--- DESCRIPTION:
--- Writes actual metrics through the production writer and reads actual app
--- projections through the production reader. SQLite's CLI normalizes literal
--- CRLF line endings and libc cannot receive raw NUL; neither may alter owned
--- string values or filters. Independent native hex receipts retain every byte.
--- No transport, filesystem, database, parser or adapter is mocked. No input
--- device, reserved hotstring menu or native cross-OS bridge is exercised.
--- ==============================================================================

local uv = require("luv")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-literals-XXXXXX"))
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0
assert(Writer.open_db(database))

local function hex(text)
	return (text:gsub(".", function(byte) return string.format("%02X", string.byte(byte)) end))
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local values = {
	"ordinary été quote' $() `literal` \\", "ordinary\tLF\nline", "",
	"\r\nleading", "middle\r\nline", "trailing\r\n", "'\r\n'\r\n'",
	"\0", "middle\0suffix", "\0leading", "trailing\0", "été\0'\r\n\tend",
}
for index, value in ipairs(values) do
	check("native metric literal " .. index .. " persists every original byte", function()
		local trigger = "owned-literal-" .. index
		assert(Writer.insert_hotstring_events("native", {{
			date = "2026-10-04", trigger = trigger, replacement = value,
		}}), "representable metric value refused rather than encoded")
		local rows = assert(Writer.query_rows("SELECT hex(replacement) FROM events_hotstring WHERE trigger='" .. trigger .. "';"))
		assert(#rows == 1 and rows[1] == hex(value), "metric value lost or changed native bytes")
	end)
end

for index, app in ipairs({ "\r\nleading-app", "middle\r\napp", "trailing-app\r\n", "été'\r\napp", "tabs\tCR\r\nLF\napp" }) do
	check("native dashboard literal filter " .. index .. " finds its independently seeded exact app", function()
		-- Seed independently of the formatter under test; the baseline's ordinary
		-- unfiltered projection must already prove the exact native app is there.
		local chars = 100 + index
		assert(Writer.exec_sql("INSERT INTO agg_app_day(device_id,date,app,chars) VALUES ('native','2026-10-04',CAST(X'"
			.. hex(app) .. "' AS TEXT)," .. chars .. ");"))
		local all = Reader.read_manifest(database, "2026-10-04", "2026-10-04")
		assert(all["2026-10-04"] and all["2026-10-04"][app] and all["2026-10-04"][app].chars == chars,
			"independent native fixture did not seed the exact application bytes")
		local filtered = Reader.read_manifest(database, "2026-10-04", "2026-10-04", { app })
		assert(filtered["2026-10-04"] and filtered["2026-10-04"][app] and filtered["2026-10-04"][app].chars == chars,
			"literal filter changed bytes or refused the already present app")
		local count = 0
		for _ in pairs(filtered["2026-10-04"]) do count = count + 1 end
		assert(count == 1, "encoded app filter admitted another application")
	end)
end

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
print(string.format("Native SQLite literal receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
