--- tests/unit/infra/field_check/test_field_check_raw_telemetry.lua

--- ==============================================================================
--- MODULE: Field Check, Raw Telemetry Rows Tests
--- DESCRIPTION:
--- The field run's `field_raw_telemetry` step counts the events_window_topo,
--- events_av and events_network rows per declared kind, and the guided steps
--- compare those counts before and after a gesture. These cases pin the
--- read-only, lock-free sqlite3 call, one report step per shared kind (0 when
--- absent), the skip with Metrics off, and, where sqlite3 exists, run the real
--- query over tables built from the shared schema so a renamed table or column
--- fails here rather than reading 0 on the Mac.
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("field_check_report")
local Telemetry = require("infra.field_check_raw_telemetry")

local function steps_of(report)
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

--- Runs the check over a canned database and sqlite3 answer.
local function run(database, code, output)
	local report, finished, call = Report.new_report("raw_telemetry"), 0, nil
	Telemetry.raw_telemetry({
		keystats_database = function() return database end,
		exec = function(executable, args, seconds, callback)
			call = { executable = executable, args = args, seconds = seconds }
			callback(code, output)
		end,
	}, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check finishes exactly once")
	return steps_of(report), call
end

local DATABASE = { path = "/Users/x/Library/Caches/Ergopti/metrics/dev/db.sqlite", present = true }

--- Reads a whole file.
local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	return text
end





helpers.describe("field_raw_telemetry: the Metrics event tables", function()
	helpers.it("reads the database read-only and lock-free and names every declared kind", function()
		local steps, call = run(DATABASE, 0, "topo:window_move|3\nnetwork:internet_down|1\nav:screen_recording_start|2\n")
		helpers.assert_eq(call.executable, "/usr/bin/sqlite3")
		helpers.assert_eq(call.args[1], "-readonly")
		helpers.assert_true(call.args[2]:match("^file:.*%?immutable=1$") ~= nil, "the immutable URI takes no lock")
		helpers.assert_eq(call.args[3], Telemetry.query())
		helpers.assert_eq(steps.telemetry_db.state, Report.STATE_PASS)
		helpers.assert_eq(steps.topo_window_move.value, "3")
		helpers.assert_eq(steps.network_internet_down.value, "1")
		helpers.assert_eq(steps.av_screen_recording_start.value, "2")
		for _, entry in ipairs(Telemetry.TABLES) do
			for kind in pairs(entry.kinds) do
				local step = steps[entry.prefix .. "_" .. kind]
				helpers.assert_not_nil(step, "no step for " .. entry.prefix .. ":" .. kind)
				helpers.assert_eq(step.state, Report.STATE_INFO)
			end
		end
		helpers.assert_eq(steps.network_vpn_connected.value, "0", "a kind with no row reads 0")
	end)

	helpers.it("skips with Metrics not started and fails a refused or timed-out read", function()
		helpers.assert_eq(run({ path = nil, present = false }).telemetry_db.state, Report.STATE_SKIP)
		helpers.assert_eq(run({ path = nil, present = false }).telemetry_db.value, "metrics_not_started")
		helpers.assert_eq(run({ path = DATABASE.path, present = false }).telemetry_db.value, "absent")
		helpers.assert_eq(run(DATABASE, 1, "").telemetry_db.value, "sqlite_exit_1")
		helpers.assert_eq(run(DATABASE, nil, nil).telemetry_db.value, "timeout")
		helpers.assert_nil(run(DATABASE, 1, "").topo_window_move, "no count from a failed read")
	end)

	helpers.it("parses only well-formed count lines", function()
		local counts = Telemetry.parse_counts("topo:window_move|3\ngarbage\nav:x|y\nnetwork:vpn_connected|12\r\n")
		helpers.assert_eq(counts["topo:window_move"], 3)
		helpers.assert_eq(counts["network:vpn_connected"], 12)
		helpers.assert_nil(counts["av:x"])
	end)

	helpers.it("runs its query over the shared schema's tables when sqlite3 exists", function()
		local sqlite = io.open("/usr/bin/sqlite3", "rb")
		if sqlite == nil then
			-- Said, not hidden: the macOS runners and Ubuntu images ship it
			print("    note: /usr/bin/sqlite3 absent, the real query was not run here")
			return
		end
		sqlite:close()
		local schema = read(helpers.driver_root() .. "../_shared/data/db/schema.sql")
		local ddl = {}
		for _, entry in ipairs(Telemetry.TABLES) do
			local statement = schema:match("(CREATE TABLE IF NOT EXISTS " .. entry.table .. "%s*%b());")
			helpers.assert_not_nil(statement, "the shared schema declares " .. entry.table)
			ddl[#ddl + 1] = statement .. ";"
		end
		local path = os.tmpname()
		-- Rows carry the recorded UTC offset since the metrics store it (KMD-1).
		local inserts = {
			"INSERT INTO events_window_topo VALUES ('d', 1, 't', '2026-11-11', 'window_move', 'a', NULL, NULL);",
			"INSERT INTO events_window_topo VALUES ('d', 2, 't', '2026-11-11', 'window_move', 'a', NULL, NULL);",
			"INSERT INTO events_network VALUES ('d', 1, 't', '2026-11-11', 'internet_up', 'a', NULL, NULL);",
		}
		local script = table.concat(ddl, "\n") .. "\n" .. table.concat(inserts, "\n") .. "\n"
		local pipe = assert(io.popen("/usr/bin/sqlite3 '" .. path .. "'", "w"))
		pipe:write(script)
		pipe:close()
		local query = assert(io.popen("/usr/bin/sqlite3 -readonly '" .. path .. "' \"" .. Telemetry.query() .. "\""))
		local output = query:read("*a")
		query:close()
		os.remove(path)
		local counts = Telemetry.parse_counts(output)
		helpers.assert_eq(counts["topo:window_move"], 2)
		helpers.assert_eq(counts["network:internet_up"], 1)
		helpers.assert_nil(counts["av:screen_recording_start"])
	end)
end)
