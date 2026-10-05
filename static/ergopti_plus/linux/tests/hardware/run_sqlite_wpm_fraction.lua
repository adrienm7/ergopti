--- tests/hardware/run_sqlite_wpm_fraction.lua
--- ==============================================================================
--- MODULE: Native SQLite Fractional WPM Persistence
--- DESCRIPTION:
--- Exercises public collector and writer APIs using synthetic owned test text,
--- real sqlite3 processes, and a private database. Software entry calls do not
--- claim evdev injection or hardware observation. No database/process stubs.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-wpm-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())

local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local Metrics = require("keylogger.metrics")
local Json = require("json")
local path = root .. "/metrics.sqlite"
local checks, failures = 0, 0

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local function unhex(value)
	return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function row_count()
	return tonumber(assert(Writer.query_rows("SELECT COUNT(*) FROM events_typing;"))[1])
end

Keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled() and Writer.is_available())
Keylogger.on_keydown("a", 1000, "owned-wpm")
Keylogger.on_keydown("b", 2300, "owned-wpm")
Keylogger.flush()
local original = assert(Writer.query_rows("SELECT wpm,hex(text),hex(events_json) FROM events_typing;"))[1]

check("public collector flush preserves fractional event-derived WPM and raw bytes", function()
	assert(row_count() == 1)
	local rate, text, packed = original:match("^([^|]+)|([^|]+)|([^|]+)$")
	assert(unhex(text) == "ab")
	local events = assert(Json.decode(unhex(packed)))
	assert(#events == 2 and events[1][1] == "a" and events[2][1] == "b")
	assert(events[1][2] == 0 and events[2][2] == 1300)
	local expected = Metrics.compute_wpm_from_events(#events, events[1][2] + events[2][2])
	assert(math.abs(tonumber(rate) - expected) < 1e-12, "fractional WPM was truncated")
end)

check("second collector flush cannot duplicate the accepted raw batch", function()
	Keylogger.flush()
	assert(row_count() == 1)
	assert(Writer.query_rows("SELECT wpm,hex(text),hex(events_json) FROM events_typing;")[1] == original)
end)

local fixtures = {
	{ 0.125, 0.125 }, { "2.75", 2.75 }, { 60, 60 }, { 0, 0 },
	{ "not numeric", 0 }, { 123456789.125, 123456789.125 }, { -0.125, -0.125 },
}
for index, fixture in ipairs(fixtures) do
	check("native writer retains admitted WPM control " .. index, function()
		assert(Writer.insert_typing_events("owned", {
			{ app = "owned-control-" .. index, text = "owned é", events_json = "[]", wpm = fixture[1] },
		}))
		local stored = assert(Writer.query_rows("SELECT wpm FROM events_typing WHERE app='owned-control-" .. index .. "';"))[1]
		assert(tonumber(stored) == fixture[2], "finite native scalar changed: " .. stored)
	end)
end

for _, nonfinite in ipairs({ math.huge, -math.huge, 0 / 0 }) do
	check("nonfinite " .. tostring(nonfinite) .. " is refused without raw-row mutation", function()
		local before = table.concat(assert(Writer.query_rows("SELECT id,wpm,hex(text),hex(events_json) FROM events_typing ORDER BY id;")), "\n")
		assert(Writer.insert_typing_events("owned", {
			{ app = "owned-invalid", text = "owned", events_json = "[]", wpm = nonfinite },
		}) == false, "nonfinite native WPM was acknowledged")
		assert(table.concat(assert(Writer.query_rows("SELECT id,wpm,hex(text),hex(events_json) FROM events_typing ORDER BY id;")), "\n") == before)
	end)
end

check("actual native trigger refusal preserves accepted rows and healthy retry", function()
	local before = row_count()
	assert(Writer.exec_sql("CREATE TRIGGER owned_refusal BEFORE INSERT ON events_typing BEGIN SELECT RAISE(ABORT,'owned refusal'); END;"))
	local batch = { { app = "owned-retry", text = "owned", events_json = "[]", wpm = 10.25 } }
	assert(Writer.insert_typing_events("owned", batch) == false and row_count() == before)
	assert(Writer.exec_sql("DROP TRIGGER owned_refusal;"))
	assert(Writer.insert_typing_events("owned", batch) and row_count() == before + 1)
	assert(tonumber(Writer.query_rows("SELECT wpm FROM events_typing WHERE app='owned-retry';")[1]) == 10.25)
end)

Writer.close_db()
local function remove_owned(file_path)
	local stat = assert(uv.fs_lstat(file_path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(file_path)) do remove_owned(file_path .. "/" .. name) end
		assert(uv.fs_rmdir(file_path))
	else assert(uv.fs_unlink(file_path)) end
end
remove_owned(root)
print(string.format("Native SQLite fractional WPM: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
