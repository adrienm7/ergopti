--- tests/unit/modules/keystats/core/test_keystats_session_events.lua

--- ==============================================================================
--- MODULE: Typing Sessions In The Linux Metrics Database
--- DESCRIPTION:
--- Windows and macOS write events_session (a session's start and end and the
--- idle spans inside it); Linux wrote none. This replays the shared vectors
--- (_shared/tests/corpus/keystats/session_events_vectors.json) through the
--- shared state machine, proves the recorder buffers its events and flushes
--- them once, and that the writer stores the canonical columns.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local Json = require("json")
local SessionEvents = require("keystats.session_events")

local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

local corpus = Json.decode(read(helpers.driver_root() .. "/../_shared/tests/corpus/keystats/session_events_vectors.json"))

helpers.describe("session events: the shared vectors", function()
	for _, case in ipairs(corpus.cases) do
		helpers.it("session-events: vector " .. case.id, function()
			local tracker = SessionEvents.new(corpus.timings)
			for index, step in ipairs(case.steps) do
				local events
				if step.op == "input" then events = tracker.input(step.at, step.keystroke)
				elseif step.op == "tick" then events = tracker.tick(step.at)
				else events = tracker.stop() end
				helpers.assert_eq(events, step.expected, case.id .. " step " .. index)
			end
		end)
	end

	helpers.it("session-events: refuses timings that cannot order an idle span before the session's end", function()
		helpers.assert_eq(pcall(SessionEvents.new, { micro_idle_ms = 10, session_timeout_ms = 10 }), false)
		helpers.assert_eq(pcall(SessionEvents.new, { micro_idle_ms = 0, session_timeout_ms = 10 }), false)
	end)
end)

helpers.describe("session events: the recorder", function()
	helpers.it("session-events: a keystroke starts a session and the daemon's stop ends it, each flushed once", function()
		local fake_writer = setmetatable({
			open_db = function() return true end,
			register_device = function() return true end,
			read_open_walk = function() return nil, true end,
			upsert_open_walk = function() return true end,
			is_available = function() return true end,
			bump_rev = function() return true end,
		}, { __index = Fakes.sqlite_writer() })
		require("tests.support.sqlite_flush_fake").attach(fake_writer)
		local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
		local previous_writer, previous_keystats = package.loaded[writer_name], package.loaded[keystats_name]
		package.loaded[writer_name], package.loaded[keystats_name] = fake_writer, nil
		local ok, err = pcall(function()
			local keystats = require(keystats_name)
			keystats.init({ sqlite_path = "/tmp/ergopti_keystats_session_mock.sqlite" })
			require("tests.support.metrics_consent_fixture").enable(keystats)
			keystats.reset_session()
			local now = math.floor(require("infra.monotonic").now_ms())
			keystats.on_keydown("a", now, "org.mozilla.firefox", 30)
			keystats.on_keydown("b", now + 100, "org.mozilla.firefox", 48)
			keystats.flush()
			helpers.assert_eq(#fake_writer.session_events, 1)
			helpers.assert_eq(fake_writer.session_events[1].row.kind, "session_start")
			keystats.flush()
			helpers.assert_eq(#fake_writer.session_events, 1, "a second flush must not replay the event")
			keystats.stop()
			helpers.assert_eq(#fake_writer.session_events, 2)
			helpers.assert_eq(fake_writer.session_events[2].row.kind, "session_end")
			helpers.assert_eq(fake_writer.session_events[2].row.duration_ms, 100)
		end)
		package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("session events: the writer", function()
	helpers.it("session-events: stores the canonical events_session columns, NULL for no duration", function()
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
			helpers.assert_true(writer.insert_session_events("owned-device", {
				{ ts = "2026-10-24 10:00:00", date = "2026-10-24", kind = "session_start" },
				{ ts = "2026-10-24 10:05:00", date = "2026-10-24", kind = "session_end", duration_ms = 300000 },
			}))
			local rows = assert(writer.query_rows(
				"SELECT kind,ifnull(duration_ms,'NULL') FROM events_session ORDER BY id;"))
			helpers.assert_eq(rows, { "session_start|NULL", "session_end|300000" })
			helpers.assert_eq(writer.insert_session_events("owned-device", {
				{ ts = "2026-10-24 10:06:00", date = "2026-10-24", kind = "nap" },
			}), false, "a kind the CHECK would drop is refused")
		end, debug.traceback)
		writer.close_db()
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(failure, 0) end
	end)
end)
