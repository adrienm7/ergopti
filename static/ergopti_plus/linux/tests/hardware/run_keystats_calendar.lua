--- tests/hardware/run_keystats_calendar.lua
--- ==============================================================================
--- MODULE: Native Capture Calendar Contract
--- DESCRIPTION:
--- Keeps capture-day rows and foreground intervals intact through asynchronous
--- SQLite receipts, delayed flushes, local DST days and acquisition refusal.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Fixture = require("tests.support.keystats_native_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local Calendar = require("modules.keystats.calendar")
local Monotonic = require("infra.monotonic")
local helpers = require("tests.helpers")
local uv = require("luv")
local original_capture, original_now = Calendar.capture, Monotonic.now_ms
local original_date, original_time = os.date, os.time
local checks = 0

--- Compares real native rows, retaining informative failures in child output.
local function equal(actual, expected)
	checks = checks + 1
	helpers.assert_eq(actual, expected)
end

--- Gives one native scenario a coupled wall/elapsed clock and isolated database.
local function scenario(day, body)
	local base = assert(original_time({ year = 2026, month = day.month, day = day.day, hour = day.hour or 23,
		min = day.min or 59, sec = day.sec or 59 }))
	local elapsed, path = 0, os.tmpname()
	Monotonic.now_ms = function() return 1000 + elapsed end
	Calendar.capture = function()
		local wall = base + elapsed / 1000
		return { wall_ms = wall * 1000, mono_ms = Monotonic.now_ms(),
			date = original_date("%Y-%m-%d", math.floor(wall)), ts = original_date("!%Y-%m-%d %H:%M:%S", math.floor(wall)) }
	end
	os.time = function(value) if value then return original_time(value) end; return math.floor(base + elapsed / 1000) end
	os.date = function(format, value) return original_date(format, value or math.floor(base + elapsed / 1000)) end
	local ok, failure = xpcall(function()
		Preferences.with(function()
			Fixture.with(function(k)
				k.init({ sqlite_path = path, log_dir = path .. ".logs" })
				require("tests.support.metrics_consent_fixture").enable(k)
				local writer = require("modules.keystats.sqlite_writer")
				local function advance(ms) elapsed = elapsed + ms end
				local function rows(sql) return assert(writer.query_rows(sql)) end
				body(k, writer, advance, rows)
			end)
		end)
	end, debug.traceback)
	Calendar.capture, Monotonic.now_ms = original_capture, original_now
	os.date, os.time = original_date, original_time
	os.remove(path)
	os.execute("rm -rf -- " .. require("text_utils").shell_quote(path .. ".logs"))
	assert(ok, failure)
end

scenario({ month = 10, day = 25 }, function(k, _, advance, rows)
	k.on_app_focus("calendar-app", Monotonic.now_ms())
	k.set_window_title("calendar-app", "original", Monotonic.now_ms())
	k.on_keydown("a", Monotonic.now_ms(), "calendar-app", 30)
	k.record_hold("calendar-app", 30, 800)
	k.record_physical_key("calendar-app", 30, Monotonic.now_ms())
	advance(2000)
	k.on_keydown("b", Monotonic.now_ms(), "calendar-app", 30)
	k.record_hold("calendar-app", 30, 100)
	k.record_physical_key("calendar-app", 30, Monotonic.now_ms())
	k.set_window_title("calendar-app", "done", Monotonic.now_ms())
	k.on_app_focus("next", Monotonic.now_ms())
	local dashboard = assert(k.get_dashboard_payload({ include_prefetch = false }))
	equal(dashboard.metrics_manifest["2026-10-25"]["calendar-app"].chars, 1)
	equal(dashboard.metrics_manifest["2026-10-26"]["calendar-app"].chars, 1)
	local range = assert(k.get_range_payload("2026-10-25", "2026-10-25", { "calendar-app" }))
	equal(range.historical.c.a.c, 1)
	equal(range.historical.c.b, nil)
	equal(next(range.today), nil)
	Fixture.flush(k)
	Fixture.reset(k)
	equal(rows("SELECT date,text FROM events_typing ORDER BY date;"), { "2026-10-25|a", "2026-10-26|b" })
	equal(rows("SELECT date,chars,app_time_ms FROM agg_app_day WHERE app='calendar-app' ORDER BY date;"),
		{ "2026-10-25|1|1000", "2026-10-26|1|1000" })
	equal(rows("SELECT date,c,ms FROM agg_app_day_titles WHERE title='original' ORDER BY date;"),
		{ "2026-10-25|1|1000", "2026-10-26|1|1000" })
	equal(rows("SELECT date,sum_ms,count,max_ms FROM agg_app_day_kc_hold ORDER BY date;"),
		{ "2026-10-25|800|1|800", "2026-10-26|100|1|100" })
	equal(rows("SELECT date,scancode,c FROM ngram_scancodes ORDER BY date;"), { "2026-10-25|30|1", "2026-10-26|30|1" })
	equal(rows("SELECT date,hour,c FROM agg_app_day_hourly ORDER BY date;"), { "2026-10-25|23|1", "2026-10-26|00|1" })

	equal(rows("SELECT date,kind,duration_ms FROM events_session ORDER BY id;"),
		{ "2026-10-25|session_start|", "2026-10-26|session_end|2000" })
end)

scenario({ month = 10, day = 25 }, function(k, writer, advance, rows)
	local start, native, released = writer.start_flush, nil, false
	writer.start_flush = function(...)
		native = assert(start(...))
		local proxy = { result = native.result }
		function proxy:pump() local complete = native:pump(); self.result = native.result; return released and complete end
		function proxy:is_settled() return released and native:is_settled() end
		function proxy:is_read_safe() return released and native:is_read_safe() end
		function proxy:is_retryable() return native:is_retryable() end
		function proxy:phase() return native:phase() end
		function proxy:cancel() return native:cancel() end
		return proxy
	end
	local ok, failure = xpcall(function()
		k.on_app_focus("calendar-app", Monotonic.now_ms())
		k.set_window_title("calendar-app", "held-prefix", Monotonic.now_ms())
		k.on_keydown("a", Monotonic.now_ms(), "calendar-app")
		equal(k.flush(), false)
		local deadline = uv.hrtime() + 10000000000
		while not native:is_settled() and uv.hrtime() < deadline do uv.run("nowait"); k.pump_flush(); uv.sleep(1) end
		assert(native:is_settled() and native.result.committed == true, "the withheld receipt must cover a genuine native COMMIT")
		equal(k.has_flush_debt(), true)
		advance(100)
		k.on_keydown("b", Monotonic.now_ms(), "calendar-app")
		advance(1900)
		k.on_keydown("c", Monotonic.now_ms(), "calendar-app")
		k.set_window_title("calendar-app", "done", Monotonic.now_ms())
		k.on_app_focus("next", Monotonic.now_ms())
		released = true
		k.pump_flush()
		equal(k.has_flush_debt(), false)
		writer.start_flush = start
		local manifest = assert(k.get_dashboard_payload({ include_prefetch = false })).metrics_manifest
		equal(manifest["2026-10-25"]["calendar-app"].chars, 2)
		equal(manifest["2026-10-26"]["calendar-app"].chars, 1)
		Fixture.flush(k)
		equal(rows("SELECT date,text FROM events_typing ORDER BY id;"),
			{ "2026-10-25|a", "2026-10-25|b", "2026-10-26|c" })
		equal(rows("SELECT date,chars FROM agg_app_day ORDER BY date;"), { "2026-10-25|2", "2026-10-26|1" })
		equal(rows("SELECT date,app_time_ms FROM agg_app_day ORDER BY date;"), { "2026-10-25|1000", "2026-10-26|1000" })
		equal(rows("SELECT date,c,ms FROM agg_app_day_titles WHERE title='held-prefix' ORDER BY date;"),
			{ "2026-10-25|2|1000", "2026-10-26|1|1000" })

		Fixture.flush(k)
		equal(rows("SELECT count(*) FROM events_typing;"), { "3" })
	end, debug.traceback)
	released, writer.start_flush = true, start
	assert(ok, failure)
end)

scenario({ month = 10, day = 25 }, function(k, writer, advance, rows)
	local start = writer.start_flush
	k.on_keydown("a", Monotonic.now_ms(), "calendar-app")
	writer.start_flush = function()
		k.on_keydown("b", Monotonic.now_ms(), "calendar-app")
		advance(2000)
		k.on_keydown("c", Monotonic.now_ms(), "calendar-app")
		return nil
	end
	local ok, failure = pcall(function() equal(k.flush(), false) end)
	writer.start_flush = start
	assert(ok, failure)
	equal(k.has_flush_debt(), false)
	Fixture.flush(k)
	equal(rows("SELECT date,text FROM events_typing ORDER BY date;"), { "2026-10-25|ab", "2026-10-26|c" })
	equal(rows("SELECT date,chars FROM agg_app_day ORDER BY date;"), { "2026-10-25|2", "2026-10-26|1" })
end)

scenario({ month = 10, day = 25, sec = 0 }, function(k, _, advance, rows)
	local shell = require("adapters.shell_runner")
	local original_line, original_has = shell.exec_line, shell.has_command
	local system = require("modules.keystats.system_metrics")
	local network = "network-one"
	shell.has_command = function(name) return name == "nmcli" or name == "loginctl" or name == "pactl" end
	shell.exec_line = function(command)
		if command:find("power_supply", 1, true) then return "50" end
		if command:find("nmcli", 1, true) then return network end
		if command:find("loginctl", 1, true) then return "no" end
		if command:find("pactl", 1, true) then return "Mute: no" end
		return ""
	end
	local ok, failure = xpcall(function()
		local function sample()
			assert(system.sample())
		end
		sample()
		advance(30000)
		network = "network-two"
		sample()
		local prefix = system.snapshot()
		advance(30000)
		network = "network-three"
		sample()
		system.acknowledge(prefix)
		equal(system.snapshot().values["2026-10-25"].awake_ms, 60000)
		advance(30000)
		sample()
		Fixture.flush(k)
		equal(rows("SELECT date,awake_ms,battery_count,wifi_changes FROM agg_system_day ORDER BY date;"),
			{ "2026-10-25|60000|2|1", "2026-10-26|30000|2|1" })
		equal(rows("SELECT date,action FROM events_system ORDER BY id;"),
			{ "2026-10-25|wifi_change", "2026-10-26|wifi_change" })
		equal(system.snapshot().values["2026-10-25"], nil)
	end, debug.traceback)
	shell.exec_line, shell.has_command = original_line, original_has
	assert(ok, failure)
end)

scenario({ month = 10, day = 25 }, function(k, _, advance, rows)
	k.on_app_focus("synthetic", Monotonic.now_ms())
	for day = 1, 2 do
		k.record_hotstring("synthetic", "x", "word", Monotonic.now_ms(), "static", 0, false)
		k.record_synthetic_output("synthetic", "z", "llm", Monotonic.now_ms(), 0, 1)
		k.record_suggestion("synthetic", "hotstring", Monotonic.now_ms())
		k.record_suggestion("synthetic", "llm", Monotonic.now_ms())
		k.record_shortcut("synthetic", "owned-shortcut", Monotonic.now_ms())
		k.record_llm_event("synthetic", "suggested", { prediction = "z" })
		k.record_pointer("press", 272, 1)
		if day == 1 then advance(2000) end
	end
	Fixture.flush(k)
	equal(rows("SELECT date,chars,hs_chars,hs_triggers,hs_suggested,llm_chars,llm_triggers,llm_suggested FROM agg_app_day ORDER BY date;"),
		{ "2026-10-25|0|4|1|1|1|1|1", "2026-10-26|0|4|1|1|1|1|1" })
	for _, table_name in ipairs({ "events_hotstring", "events_shortcut", "events_llm" }) do
		equal(rows("SELECT date,count(*) FROM " .. table_name .. " GROUP BY date ORDER BY date;"),
			{ "2026-10-25|1", "2026-10-26|1" })
	end
	equal(rows("SELECT date,mouse_clicks FROM events_typing ORDER BY date;"), { "2026-10-25|1", "2026-10-26|1" })
	equal(rows("SELECT date,hour,c FROM agg_app_day_hourly ORDER BY date;"), {})
end)

scenario({ month = 10, day = 25 }, function(k, _, advance, rows)
	k.on_app_focus("calendar-app", Monotonic.now_ms())
	k.set_window_title("calendar-app", "original", Monotonic.now_ms())
	k.on_keydown("a", Monotonic.now_ms(), "calendar-app")
	advance(2000)
	k.set_private_window(true)
	Fixture.flush(k)
	equal(rows("SELECT date,chars,app_time_ms FROM agg_app_day ORDER BY date;"), { "2026-10-25|1|0" })
	equal(rows("SELECT date,c,ms FROM agg_app_day_titles ORDER BY date;"), { "2026-10-25|1|0" })
	equal(rows("SELECT count(*) FROM events_app_switch;"), { "0" })
end)

scenario({ month = 10, day = 25 }, function(k, writer, advance, rows)
	local path = writer.get_db_path()
	assert(uv.fs_mkdir(path .. ".logs", 448))
	writer.close_db()
	assert(not writer.is_available())
	-- A real directory is refused by native admission, rather than a stubbed
	-- available flag. The same collector continues accepting permitted input.
	k.init({ sqlite_path = path .. ".logs", log_dir = path .. ".logs" })
	equal(writer.is_available(), false)
	assert(k.set_enabled(true))
	k.on_keydown("a", Monotonic.now_ms(), "recovery-app")
	equal(k.flush(), false)
	equal(k._pending_buffer_count_for_test() > 0, true)
	advance(2000)
	k.on_keydown("b", Monotonic.now_ms(), "recovery-app")
	equal(k.flush(), false)
	k.init({ sqlite_path = path, log_dir = path .. ".logs" })
	equal(writer.is_available(), true)
	Fixture.flush(k)
	equal(rows("SELECT date,text FROM events_typing ORDER BY date;"), { "2026-10-25|a", "2026-10-26|b" })
	equal(rows("SELECT date,chars FROM agg_app_day ORDER BY date;"), { "2026-10-25|1", "2026-10-26|1" })
	equal(k._pending_buffer_count_for_test(), 0)
end)

scenario({ month = 10, day = 25 }, function(k, writer)
	writer.close_db()
	k.on_keydown("a", Monotonic.now_ms(), "shutdown-app")
	local logger = require("logger.shim")
	local original, errors = logger.error, 0
	logger.error = function(tag, message, ...)
		if tag == "modules.keystats.keystats" and message == "Final SQLite history remains uncommitted; summary publication cannot acknowledge its source." then
			errors = errors + 1
		end
		return original(tag, message, ...)
	end
	local ok, failure = xpcall(function()
		equal(k.stop(), true)
		equal(k.get_flush_status().committed, false)
		equal(k.has_flush_debt(), false)
		equal(k._pending_buffer_count_for_test(), 1)
		equal(k.stop(), true)
		equal(errors, 1)
	end, debug.traceback)
	logger.error = original
	assert(ok, failure)
end)

for _, day in ipairs({ { month = 3, day = 29, hours = 23 }, { month = 10, day = 25, hours = 25 } }) do
	scenario({ month = day.month, day = day.day, hour = 0, min = 0, sec = 0 }, function(k, _, advance, rows)
		local clock = Calendar.capture()
		local length = Calendar.next_midnight(clock.wall_ms) - clock.wall_ms
		equal(length, day.hours * 60 * 60 * 1000)
		k.on_app_focus("calendar-app", Monotonic.now_ms())
		k.set_window_title("calendar-app", "dst", Monotonic.now_ms())
		advance(length + 1000)
		k.set_window_title("calendar-app", "done", Monotonic.now_ms())
		k.on_app_focus("next", Monotonic.now_ms())
		Fixture.flush(k)
		equal(rows("SELECT app_time_ms FROM agg_app_day WHERE app='calendar-app' ORDER BY date;"),
			{ string.format("%.0f", length), "1000" })
		equal(rows("SELECT ms FROM agg_app_day_titles WHERE title='dst' ORDER BY date;"), { string.format("%.0f", length), "1000" })
	end)
end
print("native capture calendar: scenarios=10 checks=" .. checks)
