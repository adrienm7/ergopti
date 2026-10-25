--- tests/hardware/run_system_event_capture.lua
--- ==============================================================================
--- MODULE: Native System Transition Capture Admission
--- DESCRIPTION:
--- Observes actual sampler, collector and SQLite receipts while controlled sensor
--- responses cross recording-policy boundaries. Machine aggregates stay independent.
--- ==============================================================================

local root, receipt = assert(arg[1]), assert(arg[2])
local shared = root .. "/../_shared/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv, Json = require("luv"), require("json")
local Preferences = require("tests.support.metrics_preferences_fixture")
local Fixture = require("tests.support.keystats_native_fixture")
local Consent = require("tests.support.metrics_consent_fixture")
local Shell = require("adapters.shell_runner")
local Clock = require("infra.monotonic")
local Calendar = require("modules.keystats.calendar")
local System = require("modules.keystats.system_metrics")
local original_has, original_line = Shell.has_command, Shell.exec_line
local original_capture, original_now = Calendar.capture, Clock.now_ms
local wall, mono = os.time() * 1000, original_now()
local elapsed, network, locked = 0, "allowed-initial-network", false
local calls = { network = 0, lock = 0, mute = 0 }
-- Existing documented sensor command boundaries return controlled software data.
Shell.has_command = function(name, ...)
	if name == "nmcli" or name == "loginctl" or name == "pactl" then return true end
	return original_has(name, ...)
end
Shell.exec_line = function(command)
	if command:find("nmcli -t -f active,ssid", 1, true) then calls.network = calls.network + 1; return "yes:" .. network end
	if command:find("loginctl show-session", 1, true) then calls.lock = calls.lock + 1; return locked and "yes" or "no" end
	if command:find("pactl get-sink-mute", 1, true) then calls.mute = calls.mute + 1; return "Mute: no" end
	return original_line(command)
end
-- Advance only the sampler/collector observation port; native libuv and SQLite
-- retain their real clocks, handles, child processes and COMMIT acknowledgements.
Clock.now_ms = function() return mono + elapsed end
Calendar.capture = function()
	local at = wall + elapsed
	return { wall_ms = at, mono_ms = Clock.now_ms(), date = os.date("%Y-%m-%d", math.floor(at / 1000)),
		ts = os.date("!%Y-%m-%d %H:%M:%S", math.floor(at / 1000)) }
end
local directory = assert(uv.fs_mkdtemp(assert(os.getenv("XDG_RUNTIME_DIR")) .. "/system-privacy-XXXXXX"))
local observations, violations, owned_databases = {}, 0, {}
local function own_database(name)
	local database = directory .. "/" .. name .. ".sqlite"
	owned_databases[#owned_databases + 1] = database
	return database
end
local function same(actual, expected)
	require("tests.helpers").assert_eq(actual, expected)
end
local ok, failure = xpcall(function()
	for _, case in ipairs({
		{ name = "allowed", policy = "none", resume_before = true, expected_rows = 3 },
		{ name = "paused-at-drain", policy = "pause", resume_before = false, expected_rows = 0 },
		{ name = "pause-resume-before-drain", policy = "pause", resume_before = true, expected_rows = 0 },
		{ name = "private-at-drain", policy = "private", resume_before = false, expected_rows = 0 },
		{ name = "private-resume-before-drain", policy = "private", resume_before = true, expected_rows = 0 },
		{ name = "allowed-around-pause", policy = "pause", resume_before = true, expected_rows = 6, allowed_prefix = true },
		{ name = "allowed-around-private", policy = "private", resume_before = true, expected_rows = 6, allowed_prefix = true },
	}) do
		elapsed, network, locked = 0, "allowed-initial-network", false
		System._reset()
		Preferences.with(function()
			Fixture.with(function(k)
				local database = own_database(case.name)
				assert(k.init({ sqlite_path = database, log_dir = directory .. "/logs" }) ~= false)
				Consent.enable(k)
				assert(k.set_private_filter_enabled(true))
				local writer = require("modules.keystats.sqlite_writer")
				assert(writer.is_available())
				assert(System.sample())
				local function set_forbidden(value)
					if case.policy == "pause" then
						if value then k.suspend_collection() else k.resume_collection() end
						assert(k.get_privacy_state().suspended == value)
					elseif case.policy == "private" then
						k.set_private_window(value)
						assert(k.get_privacy_state().private_window == value)
					end
				end
				local steps = 0
				local function transition_sample()
					steps = steps + 1
					-- The declared gap produces a structured wake as well as lock/network
					-- transitions, without advancing native process/deadline clocks.
					elapsed = elapsed + System._sample_interval_ms() * 4
					network, locked = "sample-network-" .. steps, not locked
					assert(System.sample())
				end
				if case.allowed_prefix then transition_sample() end
				set_forbidden(true)
				transition_sample()
				if case.policy ~= "none" then k.on_keydown("p", Clock.now_ms(), "privacy-probe") end
				if case.resume_before then set_forbidden(false) else Fixture.flush(k); set_forbidden(false) end
				if case.allowed_prefix then transition_sample() end
				k.on_keydown("a", Clock.now_ms(), "privacy-probe")
				Fixture.flush(k)
				local rows = assert(writer.query_rows("SELECT action,COALESCE(json_extract(metadata_json,'$.asleep_ms'),'') FROM events_system ORDER BY action;"))
				local text = assert(writer.query_rows("SELECT text FROM events_typing ORDER BY id;"))
				assert(#text == 1 and text[1] == "a", "privacy must reject the forbidden key and preserve permitted input")
				local metadata = assert(writer.query_rows("SELECT COUNT(*) FROM events_system WHERE json_extract(metadata_json,'$.asleep_ms')=" .. tostring(System._sample_interval_ms() * 4) .. ";"))
				local aggregates = assert(writer.query_rows("SELECT SUM(wifi_changes),SUM(sleep_ms) FROM agg_system_day;"))
				same(aggregates, { steps .. "|" .. elapsed })
				local expected_events = {}
				for _ = 1, case.expected_rows / 3 do
					expected_events[#expected_events + 1] = "lock|"
				end
				for _ = 1, case.expected_rows / 3 do expected_events[#expected_events + 1] = "wake|" .. (System._sample_interval_ms() * 4) end
				for _ = 1, case.expected_rows / 3 do expected_events[#expected_events + 1] = "wifi_change|" end
				local passed = #rows == case.expected_rows
				if passed then same(rows, expected_events) end
				same(tonumber(metadata[1]), #rows / 3)
				if not passed then violations = violations + 1 end
				observations[#observations + 1] = { case = case.name, expected_system_rows = case.expected_rows, aggregate_wifi_sleep = aggregates,
					actual_system_rows = #rows, events = rows, asleep_metadata_rows = tonumber(metadata[1]), permitted_text = text,
					privacy_contract_passed = passed, native_commit = k.get_flush_status().committed == true }
				print(case.name .. " " .. Json.encode(observations[#observations]))
			end)
		end)
	end
	-- Failed native storage admission must still establish capture authority.
	-- A stopped collector refuses reinitialization and cannot reauthorize samples.
	elapsed, network, locked = 0, "failed-open-initial", false
	System._reset()
	Preferences.with(function()
		Fixture.with(function(k)
			k.init({ sqlite_path = directory, log_dir = directory .. "/logs" })
			local writer = require("modules.keystats.sqlite_writer")
			assert(not writer.is_available(), "a real directory must refuse native DB admission")
			assert(k.set_enabled(true))
			assert(System.sample())
			k.set_private_window(true)
			elapsed = System._sample_interval_ms() * 4
			network, locked = "failed-open-forbidden", true
			assert(System.sample())
			k.set_private_window(false)
			same(System.take_events(), {})
			same(System.current().wifi_changes, 1)
			same(System.current().sleep_ms, elapsed)
			assert(k.flush() == false)
			local database = own_database("failed-open")
			k.init({ sqlite_path = database, log_dir = directory .. "/logs" })
			assert(writer.is_available())
			-- Recovery preserves the admitted rate clock; sensor acquisition
			-- requires a genuinely due observation rather than another cache read.
			elapsed = elapsed + System._sample_interval_ms()
			assert(System.sample())
			k.on_keydown("a", Clock.now_ms(), "privacy-probe")
			Fixture.flush(k)
			same(assert(writer.query_rows("SELECT count(*) FROM events_system;")), { "0" })
			same(assert(writer.query_rows("SELECT text FROM events_typing;")), { "a" })
			local settled = k.stop()
			local deadline = uv.hrtime() + 10000000000
			while not settled and uv.hrtime() < deadline do uv.run("nowait"); uv.sleep(1); settled = k.stop() end
			assert(settled)
			assert(k.init({ sqlite_path = database }) == false, "a retired owner must refuse reinitialization")
			elapsed = elapsed + System._sample_interval_ms() * 4
			network, locked = "after-stop", false
			assert(System.sample())
			same(System.take_events(), {})
			observations[#observations + 1] = { case = "failed-open", native_commit = true, expected_system_rows = 0,
				actual_system_rows = 0, stopped_owner_refused = true, independent_failed_day_wifi = 1 }
		end)
	end)
	assert(calls.network == 22 and calls.lock == 22 and calls.mute == 22, "every real sampler scenario must consult controlled native sensor ports")
end, debug.traceback)
Shell.has_command, Shell.exec_line = original_has, original_line
Calendar.capture, Clock.now_ms = original_capture, original_now
local payload = { runtime = _VERSION, scenarios = observations,
	contract_violations = violations, sampler_sensor_calls = calls, execution_completed = ok, execution_error = ok and nil or failure }
local output = assert(io.open(receipt, "wb")); assert(output:write(Json.encode(payload), "\n")); assert(output:close())
-- Exact scenario-owned files only; no business source is reused for fixture cleanup.
for _, database in ipairs(owned_databases) do
	os.remove(database); os.remove(database .. "-wal"); os.remove(database .. "-shm")
end
local logs = directory .. "/logs"
local scanner = uv.fs_scandir(logs)
if scanner then
	while true do local name = uv.fs_scandir_next(scanner); if not name then break end; assert(uv.fs_unlink(logs .. "/" .. name)) end
	assert(uv.fs_rmdir(logs))
end
local retired, cleanup_failure = uv.fs_rmdir(directory)
if not ok then error(failure, 0) end
assert(retired, cleanup_failure)
assert(#observations == 8, "all allowed and forbidden controls must execute")
print("native system capture policy: scenarios=" .. #observations .. " contract_violations=" .. violations)
if violations > 0 then os.exit(1) end
