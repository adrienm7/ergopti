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

--- Runs the real recorder with a scripted sampler and a fake writer.
--- @param transitions table Lists handed out by successive take_events() calls.
--- @param script function Receives the keystats module and the fake writer.
local function with_recorder(transitions, script)
	local fake_writer = setmetatable({
		open_db = function() return true end,
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
	package.loaded[names[1]], package.loaded[names[2]] = fake_writer, nil
	package.loaded[names[3]] = {
		bind = function() end,
		current = function() return nil end,
		take_events = function()
			taken = taken + 1
			return transitions[taken] or {}
		end,
	}
	local ok, err = pcall(function()
		local keystats = require(names[2])
		keystats.init({ sqlite_path = "/tmp/ergopti_keystats_system_mock.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		script(keystats, fake_writer)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("keystats system events: the recorder", function()
	helpers.it("writes the sampler's transitions once, with their metadata", function()
		with_recorder({ { { family = "system", action = "lock" },
			{ family = "system", action = "wake", metadata = { asleep_ms = 90000 } } } },
			function(keystats, writer)
				keystats.flush()
				keystats.flush()
				helpers.assert_eq(#writer.system_events, 2)
				helpers.assert_eq(writer.system_events[1].row.action, "lock")
				helpers.assert_eq(writer.system_events[2].row.metadata, { asleep_ms = 90000 })
			end)
	end)

	helpers.it("drops the transitions seen while recording is forbidden", function()
		with_recorder({ { { family = "system", action = "unlock" } } }, function(keystats, writer)
			keystats.set_enabled(false)
			keystats.flush()
			keystats.set_enabled(true)
			keystats.flush()
			helpers.assert_eq(#writer.system_events, 0)
		end)
	end)
end)

helpers.describe("keystats audio events: the recorder and the writer", function()
	helpers.it("writes the sampler's audio transitions to events_av under the focused application", function()
		with_recorder({ { { family = "av", action = "volume_change", metadata = { muted = true, change = "muted" } } } },
			function(keystats, writer)
				keystats.on_app_focus("org.mozilla.firefox", 1000)
				keystats.flush()
				helpers.assert_eq(#writer.av_events, 1)
				helpers.assert_eq(#writer.system_events, 0, "an audio change is no system event")
				helpers.assert_eq(writer.av_events[1].row.kind, "volume_change")
				helpers.assert_eq(writer.av_events[1].row.meta, { muted = true, change = "muted" })
			end)
	end)

	helpers.it("stores the canonical events_av columns", function()
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
			helpers.assert_true(writer.insert_av_events("owned-device", { { ts = "2026-10-24 10:00:00",
				date = "2026-10-24", kind = "volume_change", app = "Firefox", meta = { muted = false } } }))
			local rows = assert(writer.query_rows("SELECT kind,app,meta_json FROM events_av;"))
			helpers.assert_eq(rows, { 'volume_change|Firefox|{"muted":false}' })
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)

helpers.describe("keystats system events: the writer", function()
	helpers.it("stores the canonical events_system columns", function()
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
