--- tests/unit/modules/keystats/core/test_keystats_system_events.lua

--- ==============================================================================
--- MODULE: Machine Transitions In The Linux Metrics Database
--- DESCRIPTION:
--- Windows and macOS write events_system for the machine's transitions (lock,
--- unlock, wake, network change). Linux sampled them into agg_system_day only.
--- This proves the recorder takes the sampler's transitions at each flush,
--- writes them once, drops them while recording is forbidden, and that the
--- writer stores the canonical columns.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Home = require("tests.support.keystats_home_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")

--- Registers one case that owns its home and its metrics preferences: the
--- collector's paths and the metrics flag stay inside the case.
--- @param name string
--- @param body function
local function it(name, body)
	helpers.it(name, function() Preferences.with(function() Home.run(body) end) end)
end

--- Runs the real recorder with a scripted sampler and a fake writer.
--- @param transitions table Lists handed out by successive take_events() calls.
--- @param script function Receives the keystats module and the fake writer.
local function with_recorder(transitions, script)
	local fake_writer = setmetatable({
		open_db = function() return true end,
		ensure_token_encoding = function() return true end,
		ensure_awake_definition = function() return true end,
		register_device = function() return true end,
		read_open_walk = function() return nil, true end,
		upsert_open_walk = function() return true end,
		read_system_day = function() return nil, true end,
		is_available = function() return true end,
		bump_rev = function() return true end,
	}, { __index = Fakes.sqlite_writer() })
	require("tests.support.sqlite_flush_fake").attach(fake_writer)
	local names = { "modules.keystats.sqlite_writer", "modules.keystats.keystats", "modules.keystats.system_metrics" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local taken = 0
	local stamp = require("modules.keystats.calendar").capture()
	transitions = require("table_util").deep_copy(transitions)
	for _, batch in ipairs(transitions) do
		for _, event in ipairs(batch) do
			event.ts = event.ts or stamp.ts
			event.date = event.date or stamp.date
		end
	end
	package.loaded[names[1]], package.loaded[names[2]] = fake_writer, nil
	package.loaded[names[3]] = {
		bind = function() end,
		bind_event_capture = function() end,
		current = function() return nil end,
		snapshot = function() return { values = {}, owners = {} } end,
		acknowledge = function() end,
		take_events = function()
			taken = taken + 1
			return transitions[taken] or {}
		end,
	}
	local ok, err = pcall(function()
		local keystats = require(names[2])
		keystats.init(Home.options())
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		script(keystats, fake_writer)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("keystats system events: the recorder", function()
	it("writes the sampler's transitions once, with their metadata", function()
		with_recorder({ { { action = "lock" }, { action = "wake", metadata = { asleep_ms = 90000 } } } },
			function(keystats, writer)
				keystats.flush()
				keystats.flush()
				helpers.assert_eq(#writer.system_events, 2)
				helpers.assert_eq(writer.system_events[1].row.action, "lock")
				helpers.assert_eq(writer.system_events[2].row.metadata, { asleep_ms = 90000 })
			end)
	end)

	it("retains a system transition's sampled day across a delayed flush (system-transition-capture-day)", function()
		with_recorder({ { { action = "lock", date = "2026-10-24", ts = "2026-10-24 23:59:30" } } },
			function(keystats, writer)
				keystats.flush()
				helpers.assert_eq(#writer.system_events, 1)
				helpers.assert_eq(writer.system_events[1].row.date, "2026-10-24")
				helpers.assert_eq(writer.system_events[1].row.ts, "2026-10-24 23:59:30")
			end)
	end)

	it("linux-network-recorder: a connectivity transition reaches events_network with the Windows metadata", function()
		with_recorder({}, function(keystats, writer)
			keystats.record_network_event("vpn_connected", { adapter = "vpn", address = "10.0.0.2" })
			keystats.set_enabled(false)
			keystats.record_network_event("internet_down")
			keystats.set_enabled(true)
			keystats.flush()
			helpers.assert_eq(#writer.network_events, 1, "a transition seen while recording is off is dropped")
			helpers.assert_eq(writer.network_events[1].row.kind, "vpn_connected")
			helpers.assert_eq(writer.network_events[1].row.meta, { adapter = "vpn" },
				"only the kind's own keys are kept: no address reaches a row")
		end)
	end)

	-- KL_AppendLog refuses every entry while the focused app is filtered:
	-- Linux stored the transition with the excluded app's name, and the device
	-- ledger exported it (KML-003, linux-network-excluded-app).
	it("linux-network-excluded-app: no transition is stored under an excluded app", function()
		with_recorder({}, function(keystats, writer)
			keystats.set_disabled_apps({ "org.example.excluded" })
			keystats.on_app_focus("org.example.excluded", 1000)
			keystats.record_network_event("internet_down")
			keystats.on_app_focus("org.example.editor", 2000)
			keystats.record_network_event("internet_up")
			keystats.flush()
			helpers.assert_eq(#writer.network_events, 1, "only the transition under a recorded app")
			helpers.assert_eq(writer.network_events[1].row.kind, "internet_up")
		end)
	end)

	-- KMD-2 (decided by the maintainer on 2026-11-11): every row that does not
	-- come from typing is refused while an excluded app is focused, as on Windows.
	it("linux-topology-excluded-app: no window or capture row is stored under an excluded app", function()
		with_recorder({}, function(keystats, writer)
			keystats.set_disabled_apps({ "org.example.excluded" })
			keystats.on_app_focus("org.example.excluded", 1000)
			keystats.record_topology_event("window_move", { from_x = 0, from_y = 0, to_x = 10, to_y = 10 })
			keystats.record_topology_event("screen_recording_start", { exe = "obs" })
			keystats.on_app_focus("org.example.editor", 2000)
			keystats.record_topology_event("window_resize", { old_w = 1, old_h = 1, new_w = 2, new_h = 2 })
			keystats.record_topology_event("screen_recording_end", { exe = "obs" })
			keystats.flush()
			helpers.assert_eq(#writer.window_topo_events, 1, "only the window row under a recorded app")
			helpers.assert_eq(writer.window_topo_events[1].row.kind, "window_resize")
			helpers.assert_eq(#writer.av_events, 1, "only the capture row under a recorded app")
			helpers.assert_eq(writer.av_events[1].row.kind, "screen_recording_end")
		end)
	end)

	it("drops the transitions seen while recording is forbidden", function()		with_recorder({ { { action = "unlock" } } }, function(keystats, writer)
			keystats.set_enabled(false)
			keystats.flush()
			keystats.set_enabled(true)
			keystats.flush()
			helpers.assert_eq(#writer.system_events, 0)
		end)
	end)
end)

helpers.describe("keystats system events: the writer", function()
	it("stores the canonical events_system columns", function()
		local has_sqlite = os.execute("command -v sqlite3 >/dev/null 2>&1")
		local writer = helpers.load_module("modules.keystats.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			local opened = writer.open_db(dir .. "/metrics.sqlite")
			if not (has_sqlite == true or has_sqlite == 0) then
				helpers.assert_eq(opened, false, "without sqlite3 the writer refuses, it does not pretend")
				return
			end
			helpers.assert_true(opened)
			helpers.assert_true(writer.insert_system_events("owned-device", {
				{ ts = "2026-10-24 10:00:00", date = "2026-10-24", action = "lock" },
				{ ts = "2026-10-24 11:00:00", date = "2026-10-24", action = "wake", metadata = { asleep_ms = 90000 } },
			}))
			local rows = assert(writer.query_rows(
				"SELECT action,ifnull(metadata_json,'NULL') FROM events_system ORDER BY id;"))
			helpers.assert_eq(rows, { "lock|NULL", 'wake|{"asleep_ms":90000}' })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)

-- KMD-3 (decided by the maintainer on 2026-11-11): the days this device
-- recorded with sampled uptime are cleared once, with the definition and its
-- first date recorded, so they are never added to keep-awake time.
helpers.describe("keystats system events: the awake_ms definition", function()
	it("linux-awake-definition: clears the sampled days once and marks the definition", function()
		local has_sqlite = os.execute("command -v sqlite3 >/dev/null 2>&1")
		if not (has_sqlite == true or has_sqlite == 0) then return end
		local writer = helpers.load_module("modules.keystats.sqlite_writer")
		local dir = os.tmpname()
		os.remove(dir)
		local ok, failure = xpcall(function()
			helpers.assert_true(writer.open_db(dir .. "/metrics.sqlite"))
			helpers.assert_true(writer.query_rows("INSERT INTO agg_system_day (device_id, date, awake_ms, locked_ms) "
				.. "VALUES ('this-device','2026-11-10',3600000,60000),('other-device','2026-11-10',1200,0);") ~= nil)
			helpers.assert_true(writer.ensure_awake_definition("this-device", "2026-11-11"))
			helpers.assert_eq(writer.query_rows("SELECT device_id,awake_ms,locked_ms FROM agg_system_day ORDER BY device_id;"),
				{ "other-device|1200|0", "this-device|0|60000" }, "only this device's sampled uptime goes")
			helpers.assert_eq(writer.get_meta(writer.AWAKE_DEFINITION.key), "keep_awake_sessions")
			helpers.assert_eq(writer.get_meta(writer.AWAKE_DEFINITION.since_key), "2026-11-11")
			helpers.assert_true(writer.query_rows("UPDATE agg_system_day SET awake_ms = 5000 WHERE device_id='this-device';") ~= nil)
			helpers.assert_true(writer.ensure_awake_definition("this-device", "2026-11-12"))
			helpers.assert_eq(writer.query_rows("SELECT awake_ms FROM agg_system_day WHERE device_id='this-device';"), { "5000" },
				"a store already moved keeps its keep-awake time")
			helpers.assert_eq(writer.get_meta(writer.AWAKE_DEFINITION.since_key), "2026-11-11")
			helpers.assert_true(writer.set_meta(writer.AWAKE_DEFINITION.key, "something-else"))
			helpers.assert_eq(writer.ensure_awake_definition("this-device", "2026-11-12"), false,
				"an unknown definition is refused, not overwritten")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)

for _, failure in ipairs({ "migration", "registration", "migration_throw", "registration_throw", "open_refused", "open_throw", "open_unavailable" }) do
	it("metrics do not use SQLite after failed " .. failure, function()
		local names = { "modules.keystats.sqlite_writer", "modules.keystats.keystats", "modules.keystats.system_metrics", "modules.keystats.text_migration" }
		local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local starts, closes, registers, migrations, resumes, conversions = 0, 0, 0, 0, 0, 0
		local writer = setmetatable({
			open_db = function()
				if failure == "open_throw" then error("injected open failure") end
				if failure == "open_refused" then return false, "store_refused" end
				if failure == "open_unavailable" then return false, "sqlite_unavailable" end
				return true
			end,
			ensure_token_encoding = function()
				migrations = migrations + 1
				if failure == "migration_throw" then error("injected migration failure") end
				return failure ~= "migration"
			end,
			register_device = function()
				registers = registers + 1
				if failure == "registration_throw" then error("injected registration failure") end
				return failure ~= "registration"
			end,
			read_open_walk = function() return nil, true end,
			is_available = function() return true end,
			close_db = function() closes = closes + 1; return true end,
		}, { __index = Fakes.sqlite_writer() })
		require("tests.support.sqlite_flush_fake").attach(writer)
		local start = writer.start_flush
		writer.start_flush = function(...) starts = starts + 1; return start(...) end
		package.loaded[names[1]], package.loaded[names[2]] = writer, nil
		package.loaded[names[4]] = { resume = function() resumes = resumes + 1 end,
			start = function() conversions = conversions + 1; return true end, cancel = function() end,
			pump = function() end, is_running = function() return false end }
		package.loaded[names[3]] = { bind = function() end, bind_event_capture = function() end,
			current = function() return nil end, snapshot = function() return { values = {}, owners = {} } end,
			acknowledge = function() end, take_events = function() return {} end }
		local called, detail = pcall(function()
			local keystats = require(names[2])
			local blocked = failure ~= "open_unavailable"
			helpers.assert_eq(keystats.init(Home.options()), not blocked, "only explicit missing sqlite uses fallback")
			helpers.assert_eq(keystats.get_privacy_state().storage_blocked, blocked, "diagnostics can observe the capture gate")
			helpers.assert_eq(resumes, 0, "an unadmitted store cannot resume historical conversion")
			helpers.assert_eq(keystats.migrate_stored_text(), false)
			helpers.assert_eq(conversions, 0, "an unadmitted store cannot start historical conversion")
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.on_keydown("a", 1000, "owned-app")
			helpers.assert_eq(keystats.get_app_stats()["owned-app"] == nil, blocked, "rejected stores cannot capture unpersistable events")
			keystats.flush()
			helpers.assert_eq(starts, 0, "unadmitted SQLite must never accept a flush")
			helpers.assert_eq(closes, (failure == "open_refused" or failure == "open_throw" or failure == "open_unavailable") and 0 or 1,
				"only a successfully opened store is closed")
			local opened = failure ~= "open_refused" and failure ~= "open_throw" and failure ~= "open_unavailable"
			helpers.assert_eq(registers, opened and 1 or 0, "registration must precede migration")
			helpers.assert_eq(migrations, (failure == "migration" or failure == "migration_throw") and 1 or 0,
				"failed device registration cannot mutate n-gram encoding")
			failure = "none"
			helpers.assert_true(keystats.init(Home.options()), "healthy retry must restore admission")
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.on_keydown("b", 2000, "recovered-app")
			helpers.assert_true(keystats.get_app_stats()["recovered-app"] ~= nil, "capture resumes after successful retry")
		end)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		assert(called, detail)
	end)
end
