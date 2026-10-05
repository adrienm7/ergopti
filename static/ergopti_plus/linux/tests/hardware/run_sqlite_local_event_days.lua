--- tests/hardware/run_sqlite_local_event_days.lua
--- ==============================================================================
--- MODULE: Native SQLite Local Event Days with Controlled Clock Inputs
--- DESCRIPTION:
--- Uses explicitly simulated Lua clocks with genuine libc dates and SQLite.
--- ==============================================================================

--- tests/hardware/run_sqlite_local_event_days.lua
--- Real public collector/writer/reader APIs and SQLite with explicitly controlled
--- Lua wall-clock inputs. libc formats UTC/local dates; no SQL/process/provider
--- mocks and no input/hardware claims. Menus/configuration are not exercised.
local uv = require("luv")
local ffi = require("ffi")
require("compat.utf8").install()
ffi.cdef("void tzset(void);")
local native_date, native_time = os.date, os.time
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-local-event-days-XXXXXX"))
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
local Json = require("json")
local checks, failures = 0, 0
local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function rows(table_name)
	return assert(Writer.query_rows("SELECT id,date,ts FROM " .. table_name .. " ORDER BY id;"))
end
local function packed()
	return table.concat(assert(Writer.query_rows("SELECT id,date,ts FROM events_typing UNION ALL SELECT id,date,ts FROM events_hotstring "
		.. "UNION ALL SELECT id,date,ts FROM events_shortcut UNION ALL SELECT id,date,ts FROM events_app_switch ORDER BY id;")), "\n")
end
local fixtures = {
	{ name = "east of UTC", tz = "OWN-2", utc = { year = 2026, month = 1, day = 1, hour = 23, min = 30 } },
	{ name = "west of UTC", tz = "OWN5", utc = { year = 2026, month = 1, day = 2, hour = 1, min = 30 } },
	{ name = "UTC healthy", tz = "OWN0", utc = { year = 2026, month = 1, day = 2, hour = 12 } },
	{ name = "local midnight east", tz = "OWN-2", utc = { year = 2026, month = 1, day = 1, hour = 22 } },
	{ name = "before local midnight west", tz = "OWN5", utc = { year = 2026, month = 1, day = 2, hour = 4, min = 59, sec = 59 } },
	{ name = "local midnight west", tz = "OWN5", utc = { year = 2026, month = 1, day = 2, hour = 5 } },
	{ name = "UTC midnight east", tz = "OWN-2", utc = { year = 2026, month = 1, day = 2, hour = 0 } },
	{ name = "UTC midnight between record and flush", tz = "OWN-2", utc = { year = 2026, month = 1, day = 1, hour = 23, min = 59, sec = 59 }, advance = 2 },
}
for index, fixture in ipairs(fixtures) do
	assert(uv.os_setenv("TZ", "OWN0")); ffi.C.tzset()
	local instant = native_time(fixture.utc)
	assert(uv.os_setenv("TZ", fixture.tz)); ffi.C.tzset()
	os.date = function(format, timestamp) return native_date(format, timestamp or instant) end
	os.time = function(date) return date and native_time(date) or instant end
	Writer.close_db()
	local path = root .. "/owned-" .. index .. ".sqlite"
	Keylogger.init({ sqlite_path = path, log_dir = root .. "/logs" })
	assert(Keylogger.is_enabled() and Writer.is_available())
	local local_day, recorded_ts = os.date("%Y-%m-%d"), os.date("!%Y-%m-%d %H:%M:%S")
	Keylogger.record_hotstring("owned-events", "q", "abc", 1000, "static", 0, false)
	Keylogger.record_shortcut("owned-events", "owned-action", 1000)
	instant = instant + (fixture.advance or 0)
	assert(os.date("%Y-%m-%d") == local_day, "fixture must not change the flush calendar day")
	Keylogger.flush()
	local hotstrings, shortcuts, typing = rows("events_hotstring"), rows("events_shortcut"), rows("events_typing")
	local before, revision = packed(), assert(Writer.get_revision())
	local manifest = Reader.read_manifest(path)
	local dashboard = Keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest
	Keylogger.flush()
	print("native " .. fixture.name .. " local=" .. local_day .. "; typing=" .. typing[1] .. "; hotstring=" .. hotstrings[1] .. "; shortcut=" .. shortcuts[1])
	check(fixture.name .. ": public raw days agree with local aggregates and retain UTC instants/IDs", function()
		assert(#hotstrings == 1 and #shortcuts == 1 and #typing == 1)
		assert(hotstrings[1] == "2|" .. local_day .. "|" .. recorded_ts)
		assert(shortcuts[1] == "3|" .. local_day .. "|" .. recorded_ts)
		assert(typing[1] == "1|" .. local_day .. "|" .. os.date("!%Y-%m-%d %H:%M:%S"))
		assert(manifest[local_day]["owned-events"].hs_chars == 3 and dashboard[local_day]["owned-events"].hs_chars == 3)
		assert(assert(Writer.query_rows("SELECT trigger||'|'||replacement||'|'||h_type||'|'||net_saved_chars FROM events_hotstring;"))[1] == "q|abc|static|2")
		assert(assert(Writer.query_rows("SELECT key FROM events_shortcut;"))[1] == "owned-action")
		assert(packed() == before and Writer.get_revision() == revision + 1)
	end)
	if index == 1 then
		assert(Writer.register_device("owned-adapter", "owned adapter", "linux", "", ""))
		local methods = {
			{ name = "typing", table_name = "events_typing", method = "insert_typing_events", event = { app = "owned-adapter", text = "owned", events_json = "[]" } },
			{ name = "hotstring", table_name = "events_hotstring", method = "insert_hotstring_events", event = { app = "owned-adapter", trigger = "q", replacement = "owned" } },
			{ name = "shortcut", table_name = "events_shortcut", method = "insert_shortcut_events", event = { app = "owned-adapter", key = "owned" } },
			{ name = "app switch", table_name = "events_app_switch", method = "insert_app_switch_events", event = { prev_app = "owned-before", next_app = "owned-after", duration_ms = 17 } },
		}
		for position, method in ipairs(methods) do
			local event = method.event
			local original = Json.encode(event)
			assert(Writer[method.method]("owned-adapter", { event }))
			local default_rows = rows(method.table_name)
			local default_row = default_rows[#default_rows]
			local untouched = Json.encode(event) == original
			event.date, event.ts = "1999-12-31", "1999-12-31 23:59:59"
			local explicit = Json.encode(event)
			assert(Writer[method.method]("owned-adapter", { event }))
			local explicit_rows = rows(method.table_name)
			local explicit_row = explicit_rows[#explicit_rows]
			print("native " .. method.name .. " default=" .. default_row .. "; explicit=" .. explicit_row)
			check(method.name .. ": absent native adapter day uses local date and UTC default timestamp", function()
				assert(default_row == (2 * position + 2) .. "|" .. local_day .. "|" .. os.date("!%Y-%m-%d %H:%M:%S"))
				assert(untouched)
			end)
			check(method.name .. ": explicit historical day/timestamp and caller table remain byte-identical", function()
				assert(explicit_row == (2 * position + 3) .. "|1999-12-31|1999-12-31 23:59:59")
				assert(Json.encode(event) == explicit)
			end)
		end
		check("all raw adapters conserve globally reserved native IDs and row counts", function()
			local all = assert(Writer.query_rows("SELECT COUNT(*),COUNT(DISTINCT id),MIN(id),MAX(id) FROM (SELECT id FROM events_typing "
				.. "UNION ALL SELECT id FROM events_hotstring UNION ALL SELECT id FROM events_shortcut UNION ALL SELECT id FROM events_app_switch);"))
			assert(all[1] == "11|11|1|11" and Writer.get_meta("linux_next_event_id") == "12")
		end)
		Keylogger.record_hotstring("owned-events", "private-owned", "xyz", 1000, "static", 0, true)
		Keylogger.flush()
		check("private public logging retains aggregate counts and withholds raw hotstring content", function()
			assert(#rows("events_hotstring") == 3, "private output must not append a raw hotstring row")
			assert(Reader.read_manifest(path)[local_day]["owned-events"].hs_chars == 6)
		end)
		local accepted = packed()
		Keylogger.suppress()
		Keylogger.record_hotstring("owned-events", "suppressed", "unused", 1000, "static", 0, false)
		Keylogger.record_shortcut("owned-events", "suppressed-action", 1000)
		Keylogger.unsuppress()
		Keylogger.flush()
		check("suppressed public producers cannot append raw rows", function() assert(packed() == accepted) end)
	end
	os.date, os.time = native_date, native_time
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
assert(checks == 19, "all 19 local-day checks must execute")
print(string.format("Native SQLite local event days with owned clock input: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
