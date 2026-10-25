--- tests/hardware/run_system_bind_recovery.lua
--- ==============================================================================
--- MODULE: Native System Metrics First-Bind Recovery
--- DESCRIPTION:
--- Samples the actual machine while the intended database path is refused,
--- then merges that retained history with a real preexisting SQLite baseline.
--- No clock, filesystem, sensor or database API is replaced.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv = require("luv")
local Fixture = require("tests.support.keystats_native_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local dir = assert(uv.fs_mkdtemp(assert(os.getenv("TMPDIR")) .. "/system-bind-recovery-XXXXXX"))
local database = dir .. "/metrics.sqlite"
assert(uv.fs_mkdir(database, 448))
local ok, failure = xpcall(function()
	Preferences.with(function()
		Fixture.with(function(k)
			k.init({ sqlite_path = database, log_dir = dir })
			local writer = require("modules.keystats.sqlite_writer")
			assert(not writer.is_available(), "an actual directory must refuse database admission")
			local system = require("modules.keystats.system_metrics")
			assert(system.sample())
			uv.sleep(system._sample_interval_ms() + 100)
			local current = assert(system.sample())
			local before, total = system.snapshot().values, 0
			for _, day in pairs(before) do total = total + day.awake_ms + day.locked_ms + day.sleep_ms end
			assert(total >= system._sample_interval_ms(), "the fixture must capture genuine elapsed machine time")
			assert(uv.fs_rmdir(database))
			assert(writer.open_db(database))
			local hostname = assert(uv.os_gethostname()):gsub("%s+", "")
			local device = "linux-" .. hostname
			assert(writer.register_device(device, hostname, "linux", "", hostname))
			local baseline = 4000
			assert(writer.upsert_system_day(device, { date = current.date, awake_ms = baseline }))
			writer.close_db()
			k.init({ sqlite_path = database, log_dir = dir })
			assert(writer.is_available() and writer.get_db_path() == database)
			local after = system.snapshot().values
			for date, day in pairs(before) do
				assert(after[date], "first binding discarded a captured calendar day")
				local expected = day.awake_ms + (date == current.date and baseline or 0)
				assert(after[date].awake_ms == expected, "first binding must merge retained deltas and persisted baseline once")
				assert(after[date].locked_ms == day.locked_ms and after[date].sleep_ms == day.sleep_ms)
			end
			assert(system.current() == system.snapshot().owners[current.date], "current day must retain the merged owner")
			Fixture.flush(k)
			local rows = assert(writer.query_rows("SELECT SUM(awake_ms+locked_ms+sleep_ms) FROM agg_system_day;"))
			assert(tonumber(rows[1]) == total + baseline, "the actual SQLite row must retain every captured elapsed interval")
			print("Native system binding recovery: captured_ms=" .. total .. "; persisted_ms=" .. rows[1] .. "; no failures")
		end)
	end)
end, debug.traceback)
for name in uv.fs_scandir_next, assert(uv.fs_scandir(dir)) do
	local path = dir .. "/" .. name
	if uv.fs_lstat(path).type == "directory" then assert(uv.fs_rmdir(path)) else assert(uv.fs_unlink(path)) end
end
assert(uv.fs_rmdir(dir))
assert(ok, failure)
