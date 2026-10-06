--- tests/hardware/run_system_day_restart.lua
--- ==============================================================================
--- MODULE: Native System-Day Restart Hydration (Linux)
--- DESCRIPTION:
--- Actual public collector, sampler and SQLite operations in separate processes.
--- Elapsed awake time is native; historical sensor rows are supplied software data.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local Json = require("json")
local Clock = require("infra.monotonic")
local K = require("modules.keylogger.keylogger")
local Metrics = require("modules.keylogger.system_metrics")
local W = require("modules.keylogger.sqlite_writer")
local phase, database, receipt = assert(arg[1]), assert(arg[2]), assert(arg[3])
local date = os.date("%Y-%m-%d")
local checks, failures = 0, 0
local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function init(db)
	K.init({ sqlite_path = db, log_dir = os.getenv("XDG_STATE_HOME") .. "/logs" })
	assert(W.is_available() and W.get_db_path() == db)
end
local function row(device, day)
	local out = assert(W.query_rows("SELECT wifi_changes,battery_sum,battery_count,battery_min,"
		.. "battery_max,audio_muted_ms,locked_ms,sleep_ms,awake_ms FROM agg_system_day WHERE device_id='"
		.. device .. "' AND date='" .. day .. "';"))
	return out[1]
end
local function now() return math.floor(Clock.now_ms()) end
init(database)
local device = assert(W.query_rows("SELECT device_id FROM devices WHERE os='linux';"))[1]
assert(device and device:match("^linux%-[a-zA-Z0-9_.%-]+$"))
assert(Clock.backend() == "luv.hrtime")
local observation
if phase == "first" then
	assert(Metrics.current() == nil)
	assert(Metrics.sample(now(), date))
	uv.sleep(30080)
	local day = assert(Metrics.sample(now(), date))
	assert(os.date("%Y-%m-%d") == date)
	K.flush()
	check("native awake time accumulates before restart", function()
		assert(day.awake_ms >= 30000 and day.awake_ms < 90000)
		assert(tonumber(assert(row(device, date)):match("([^|]+)$")) == day.awake_ms)
	end)
	check("same-process cumulative collector flush is idempotent", function()
		local before = row(device, date)
		K.flush()
		assert(row(device, date) == before)
	end)
	-- Explicit supplied history for sensors unavailable in the container.
	local history = { date = date, wifi_changes = 4, battery_sum = 150, battery_count = 2,
		battery_min = 70, battery_max = 80, audio_muted_ms = 1000, locked_ms = 2000,
		sleep_ms = 3000, awake_ms = day.awake_ms }
	assert(W.upsert_system_day(device, history))
	observation = { date = date, device = device, awake_ms = day.awake_ms, pid = uv.os_getpid() }
	local file = assert(io.open(receipt, "w")); file:write(Json.encode(observation)); file:close()
	assert(checks == 2)
else
	local file = assert(io.open(receipt, "r")); local saved = Json.decode_lossless(file:read("*a")); file:close()
	assert(saved.date == date and saved.device == device and saved.pid ~= uv.os_getpid())
	assert(Metrics.current() == nil)
	local original = assert(row(device, date))
	K.flush()
	assert(row(device, date) == original, "no first sample means no destructive flush")
	local day = assert(Metrics.sample(now(), date))
	K.flush()
	check("restart preserves genuine native awake time", function() assert(day.awake_ms == saved.awake_ms) end)
	check("restart preserves supplied wifi and duration history", function()
		assert(day.wifi_changes == 4 and day.audio_muted_ms == 1000 and day.locked_ms == 2000 and day.sleep_ms == 3000)
	end)
	check("restart preserves supplied battery history", function()
		assert(day.battery_sum == 150 and day.battery_count == 2 and day.battery_min == 70 and day.battery_max == 80)
	end)
	check("repeated restarted collector flush stays idempotent", function()
		local before = row(device, date); K.flush(); assert(row(device, date) == before)
	end)
	check("checked native getter returns the exact owned baseline", function()
		local loaded, accepted = W.read_system_day(device, date)
		assert(accepted and loaded.date == date and loaded.awake_ms == saved.awake_ms)
	end)
	check("checked native getter isolates other device history", function()
		assert(W.upsert_system_day("owned-other", { date = date, awake_ms = 666 }))
		local other, accepted = W.read_system_day("owned-other", date)
		local owned, owned_ok = W.read_system_day(device, date)
		assert(accepted and owned_ok and other.awake_ms == 666 and owned.awake_ms == day.awake_ms)
	end)
	check("checked native absent baseline is acknowledged", function()
		local absent, accepted = W.read_system_day("owned-absent", date)
		assert(accepted == true and absent == nil)
	end)
	check("checked native NULL battery bounds remain absent", function()
		assert(W.upsert_system_day("owned-null", { date = date }))
		local loaded, accepted = W.read_system_day("owned-null", date)
		assert(accepted and loaded.battery_sum == 0 and loaded.battery_count == 0)
		assert(loaded.battery_min == nil and loaded.battery_max == nil)
	end)
	check("native read failure prevents overwrite and retries after recovery", function()
		assert(type(Metrics.bind) == "function" and type(W.read_system_day) == "function")
		local before = row(device, date)
		Metrics._reset(); init(database)
		assert(W.exec_sql("ALTER TABLE agg_system_day RENAME TO owned_system_backup;"))
		local sampled = Metrics.sample(now(), date)
		local current = Metrics.current()
		K.flush()
		-- Restore before asserting so a failing observation cannot strand the fixture.
		assert(W.exec_sql("ALTER TABLE owned_system_backup RENAME TO agg_system_day;"))
		assert(sampled == nil and current == nil)
		assert(row(device, date) == before)
		local recovered = assert(Metrics.sample(now(), date))
		K.flush()
		assert(recovered.awake_ms == saved.awake_ms and row(device, date) == before)
	end)
	check("same database reopen retains live sampler and cumulative row", function()
		local current = assert(Metrics.current())
		local before = row(device, date)
		W.close_db(); init(database)
		assert(Metrics.current() == current)
		assert(Metrics.sample(now(), date) == current)
		K.flush(); assert(row(device, date) == before)
	end)
	check("changed native database isolates same-day sampler history", function()
		assert(type(Metrics.bind) == "function")
		local before = row(device, date)
		W.close_db(); init(database .. ".other")
		assert(Metrics.current() == nil)
		assert(Metrics.sample(now(), date).awake_ms == 0)
		K.flush(); assert(tonumber(assert(row(device, date)):match("([^|]+)$")) == 0)
		W.close_db(); init(database)
		assert(Metrics.current() == nil)
		assert(Metrics.sample(now(), date).awake_ms == saved.awake_ms)
		K.flush(); assert(row(device, date) == before)
	end)
	check("modeled next-date baseline is isolated without old clock handoff", function()
		assert(type(W.read_system_day) == "function")
		local next_date = os.date("%Y-%m-%d", os.time() + 86400)
		assert(W.upsert_system_day(device, { date = next_date, awake_ms = 888 }))
		local next_day = assert(Metrics.sample(now(), next_date))
		assert(next_day.date == next_date and next_day.awake_ms == 888 and next_day.sleep_ms == 0)
	end)
	observation = { date = date, device = device, pid = uv.os_getpid(), prior_awake_ms = saved.awake_ms,
		first_restarted_day = day, libuv = uv.version_string(), lua = _VERSION, clock = Clock.backend() }
	assert(checks == 12, "all twelve restart and isolation subjects must execute")
end
print("OBSERVATION " .. Json.encode(observation))
print(string.format("Native system-day restart %s: %d checks, %d failures", phase, checks, failures))
W.close_db()
os.exit(failures == 0 and 0 or 1)
